require 'pg'
require 'sequel'
require 'attr_pouch/errors'

module AttrPouch
  def self.configure
    @@config ||= Config.new
    yield @@config
  end

  def self.config
    @@config ||= Config.new
  end

  def self.included(base)
    base.extend(ClassMethods)
  end

  class Field
    attr_reader :name, :type, :raw_type, :opts

    def self.encode(type, &block)
      @@encoders ||= {}
      @@encoders[type] = block
    end

    def self.decode(type, &block)
      @@decoders ||= {}
      @@decoders[type] = block
    end

    def self.encoders; @@encoders; end
    def self.decoders; @@decoders; end

    def self.infer_type(field=nil, &block)
      if block_given?
        @@type_inferrer = block
      else
        if @@type_inferrer.nil?
          raise InvalidFieldError, "No type inference configured"
        else
          type = @@type_inferrer.call(field)
          if type.nil?
            raise InvalidFieldError, "Could not infer type of field #{field}"
          end
          type
        end
      end
    end

    def initialize(name, type, opts)
      @name = name
      if type.nil?
        @type = self.class.infer_type(self)
      else
        @type = to_class(type)
      end
      @raw_type = type
      @opts = opts
    end

    def alias_as(new_name)
      if new_name == name
        self
      else
        self.class.new(new_name, type, opts)
      end
    end

    def required?
      !(has_default? || deletable?)
    end

    def has_default?
      opts.has_key?(:default)
    end

    def default
      opts.fetch(:default, nil)
    end

    def immutable?
      opts.fetch(:immutable, false)
    end

    def deletable?
      opts.fetch(:deletable, false)
    end

    def previous_aliases
      was = opts.fetch(:was, [])
      was.is_a?(Array) ? was : [ was ]
    end

    def all_names
      [ name ] + previous_aliases
    end

    def write(store, value, encode: true)
      if store.has_key?(name)
        raise ImmutableFieldUpdateError if immutable?
      end
      if encode
        self.encode_to(store, value)
      else
        store[name] = value
      end
      previous_aliases.each { |a| store.delete(a) }
    end

    def read(store, decode: true)
      present_as = all_names.find { |n| store.has_key?(n) }
      if store.nil? || present_as.nil?
        if required?
          raise MissingRequiredFieldError,
                "Expected field #{inspect} to exist"
        else
          default if decode
        end
      elsif present_as == name
        if decode
          decode_from(store)
        else
          store.fetch(name)
        end
      else
        alias_as(present_as).read(store)
      end
    end

    def decode_from(store)
      self.class.decoders.find(method(:ensure_decoder)) do |decoder_type, _|
        self.type <= decoder_type rescue false
      end.last.call(self, store)
    end

    def encode_to(store, value)
      self.class.encoders.find(method(:ensure_encoder)) do |encoder_type, _|
        self.type <= encoder_type rescue false
      end.last.call(self, store, value)
    end

    private

    def ensure_encoder
      raise MissingCodecError,
            "No encoder found for #{inspect}"
    end

    def ensure_decoder
      raise MissingCodecError,
            "No decoder found for #{inspect}"
    end

    def to_class(type)
      return type if type.is_a?(Class) || type.is_a?(Symbol)
      type.to_s.split('::').inject(Object) do |moodule, klass|
        moodule.const_get(klass)
      end
    end
  end

  class Config
    def initialize
      @encoders = {}
      @decoders = {}
    end

    def infer_type(&block)
      if block_given?
        Field.infer_type(&block)
      else
        raise ArgumentError, "Expected block to infer types with"
      end
    end

    def write(type, &block)
      Field.encode(type, &block)
    end

    def read(type, &block)
      Field.decode(type, &block)
    end
  end

  class Pouch
    VALID_FIELD_NAME_REGEXP = %r{\A[a-zA-Z0-9_]+\??\z}

    def initialize(host, storage_field, default_pouch: Sequel.hstore({}))
      @host = host
      @storage_field = storage_field
      @default_pouch = default_pouch
    end

    def field(name, type, opts={})
      unless VALID_FIELD_NAME_REGEXP.match(name)
        raise InvalidFieldError, "Field name must match #{VALID_FIELD_NAME_REGEXP}"
      end

      field = Field.new(name, type, opts)

      storage_field = @storage_field
      default = @default_pouch

      @host.class_eval do
        define_method(name) do
          store = self[storage_field]
          field.read(store)
        end

        define_method("#{name.to_s.sub(/\?\z/, '')}=") do |value|
          store = self[storage_field]
          was_nil = store.nil?
          store = default if was_nil
          field.write(store, value)
          if was_nil
            self[storage_field] = store
          else
            modified! storage_field
          end
        end

        if field.deletable?
          delete_method = "delete_#{name.to_s.sub(/\?\z/, '')}"
          define_method(delete_method) do
            store = self[storage_field]
            unless store.nil?
              field.all_names.each { |a| store.delete(a) }
              modified! storage_field
            end
          end

          define_method("#{delete_method}!") do
            self.public_send(delete_method)
            save_changes
          end
        end

        if opts.has_key?(:raw_field)
          raw_name = opts[:raw_field]

          define_method(raw_name) do
            store = self[storage_field]
            field.read(store, decode: false)
          end

          define_method("#{raw_name.to_s.sub(/\?\z/, '')}=") do |value|
            store = self[storage_field]
            was_nil = store.nil?
            store = default if was_nil
            field.write(store, value, encode: false)
            if was_nil
              self[storage_field] = store
            else
              modified! storage_field
            end
          end
        end
      end
    end
  end

  module ClassMethods
    def pouch(field, &block)
      pouch = Pouch.new(self, field)
      pouch.instance_eval(&block)
    end
    # Add a dataset_method `where_pouch_field(pouch, expr_hash)` that
    # behaves like `where` does for normal fields. A start is
    #
    #   where(Sequel.hstore_op(pouch.field).contains(expr_hash)))
    #
    # but this doesn't behave how one might expect with
    #  - arrays: the array is serialized to a single hstore element
    #     (unlike the automatic IN translation for native attributes)
    #  - nil: the hstore column is checked for the existence of a key
    #    pointing to a null value: the absence of a key is not considered
    #    equivalent
  end
end

AttrPouch.configure do |config|
  config.write(String) do |field, store, value|
    store[field.name] = value.to_s
  end
  config.read(String) do |field, store|
    store[field.name]
  end

  config.write(Integer) do |field, store, value|
    store[field.name] = value
  end
  config.read(Integer) do |field, store|
    Integer(store[field.name])
  end
  
  config.write(Float) do |field, store, value|
    store[field.name] = value
  end
  config.read(Float) do |field, store|
    Float(store[field.name])
  end

  config.write(Time) do |field, store, value|
    store[field.name] = value.strftime('%Y-%m-%d %H:%M:%S.%N')
  end
  config.read(Time) do |field, store|
    Time.parse(store[field.name])
  end

  config.write(:bool) do |field, store, value|
    store[field.name] = value.to_s
  end
  config.read(:bool) do |field, store, value|
    store[field.name] == 'true'
  end

  config.write(Sequel::Model) do |field, store, value|
    klass = field.type
    store[field.name] = value[klass.primary_key]
  end
  config.read(Sequel::Model) do |field, store|
    klass = field.type
    klass[store[field.name]]
  end

  config.infer_type do |field|
    case field.name
    when /\Anum_|_(?:count|size)\z/
      Integer
    when /_(?:at|by)\z/
      Time
    when /\?\z/
      :bool
    else
      String
    end
  end
end
