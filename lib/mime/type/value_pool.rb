# frozen_string_literal: true

##
module MIME
  ##
  class Type
    module ValuePool # :nodoc:
      @value_pool = Hash.new { |h, k| #:nodoc:
        begin
          k = k.dup
        rescue TypeError
          k
        else
          k.freeze
        end

        h[k] = k
      }

      def self.[](k)
        @value_pool[k]
      end

      private

      def pooled_writer(sym, is_private: false) # :nodoc:
        ivar = :"@#{sym}"
        writer = :"#{sym}="
        define_method writer do |val|
          instance_variable_set(ivar, MIME::Type::ValuePool[val])
        end
        private writer if is_private
      end

      def pooled_accessor(sym, private_writer: false) # :nodoc:
        attr_reader sym
        pooled_writer sym, is_private: private_writer
      end
    end
  end
end
