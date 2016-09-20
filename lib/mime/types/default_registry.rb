# == The Default mime-types Registry
#
# The default mime-types registry is loaded automatically when the library
# is required (<tt>require 'mime/types'</tt>), but it may be lazily loaded
# (loaded on first use) with the use of the environment variable
# +RUBY_MIME_TYPES_LAZY_LOAD+ having any value other than +false+. The
# initial startup is about 14× faster (~10 ms vs ~140 ms), but the
# registry will be loaded at some point in the future.
#
# The default mime-types registry can also be loaded from a Marshal cache
# file specific to the version of MIME::Types being loaded. This will be
# handled automatically with the use of a file referred to in the
# environment variable +RUBY_MIME_TYPES_CACHE+. MIME::Types will attempt to
# load the registry from this cache file (MIME::Type::Cache.load); if it
# cannot be loaded (because the file does not exist, there is an error, or
# the data is for a different version of mime-types), the default registry
# will be loaded from the normal JSON version and then the cache file will
# be *written* to the location indicated by +RUBY_MIME_TYPES_CACHE+. Cache
# file loads just over 4½× faster (~30 ms vs ~140 ms).
# loads.
#
# Notes:
# *   The loading of the default registry is *not* atomic; when using a
#     multi-threaded environment, it is recommended that lazy loading is not
#     used and mime-types is loaded as early as possible.
# *   Cache files should be specified per application in a multiprocess
#     environment and should be initialized during deployment or before forking
#     to minimize the chance that the multiple processes will be trying to
#     write to the same cache file at the same time, or that two applications
#     that are on different versions of mime-types would be thrashing the
#     cache.
# *   Unless cache files are preinitialized, the application using the
#     mime-types cache file must have read/write permission to the cache file.
module MIME::Types::DefaultRegistry
  include Enumerable

  # MIME::Types#[] against the default MIME::Types registry.
  def [](type_id, complete: false, registered: false)
    __types__[type_id, complete: complete, registered: registered]
  end

  # MIME::Types#count against the default MIME::Types registry.
  def count
    __types__.count
  end

  # MIME::Types#each against the default MIME::Types registry.
  def each
    if block_given?
      __types__.each { |t| yield t }
    else
      enum_for(:each)
    end
  end

  # In the default registry, finds the MIME::Type objects, if any, that are
  # commonly mapped to the file extension of the +filename+ (or the full
  # +filename+ if no extension can be detected).
  #
  # Returns a merged, flattened, unique, priority sorted array.
  #
  # This method uses the default MIME::Types registry.
  #
  #   puts MIME::Types.type_for('citydesk.xml')
  #     => [application/xml, text/xml]
  #   puts MIME::Types.type_for('citydesk.gif')
  #     => [image/gif]
  #   puts MIME::Types.type_for(%w(citydesk.xml citydesk.gif))
  def type_for(filename)
    __types__.type_for(filename)
  end
  alias of type_for

  # Add one or more MIME::Type objects to the default registry. If the type is
  # already known, a warning will be displayed.
  #
  # The last parameter may be the value <tt>:silent</tt> or +true+ which will
  # suppress duplicate MIME type warnings.
  def add(*types)
    __types__.add(*types)
  end

  private

  def lazy_load?
    (lazy = ENV['RUBY_MIME_TYPES_LAZY_LOAD']) && (lazy != 'false')
  end

  def __types__
    (defined?(@__types__) and @__types__) or load_default_mime_types
  end

  unless private_method_defined?(:load_mode)
    def load_mode
      { columnar: true }
    end
  end

  def load_default_mime_types(mode = load_mode)
    @__types__ = MIME::Types::Cache.load
    unless @__types__
      @__types__ = MIME::Types::Loader.load(mode)
      MIME::Types::Cache.save(@__types__)
    end
    @__types__
  end
end

##
class MIME::Types
  extend MIME::Types::DefaultRegistry
  load_default_mime_types(load_mode) unless lazy_load?
end
