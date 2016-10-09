# frozen_string_literal: true

require_relative 'type/value_pool'

##
# The definition of one MIME content-type.
#
# == Usage
#
#   require 'mime/types'
#
#   text = MIME::Types['text/plain'].first # => #<MIME::Type: text/plain>
#   print text.media_type           # => 'text'
#   print text.sub_type             # => 'plain'
#
#   puts text.extensions.join(" ")  # => 'txt asc c cc h hh cpp'
#
#   puts text.encoding              # => 8bit
#   puts text.binary?               # => false
#   puts text.ascii?                # => true
#   puts text == 'text/plain'       # => true
#   puts MIME::Type.simplified('x-appl/x-zip') # => 'x-appl/x-zip'
#
#   puts MIME::Types.any? { |type| type.content_type == 'text/plain' } # => true
#   puts MIME::Types.all?(&:registered?) # => false
class MIME::Type
  extend MIME::Type::ValuePool

  # Reflects a MIME content-type specification that is not correctly
  # formatted (it isn't +type+/+subtype+).
  class InvalidContentType < ArgumentError
    def initialize(type_string) #:nodoc:
      @type_string = type_string
    end

    def to_s #:nodoc:
      "Invalid Content-Type #{@type_string.inspect}"
    end
  end

  # Reflects an unsupported MIME encoding.
  class InvalidEncoding < ArgumentError
    def initialize(encoding) #:nodoc:
      @encoding = encoding
    end

    def to_s #:nodoc:
      "Invalid Encoding #{@encoding.inspect}"
    end
  end

  # The released version of the mime-types library.
  VERSION = '3.1'

  include Comparable

  # :stopdoc:
  MEDIA_TYPE_RE    = %r{([[:alpha:]][-\w.+]*)/([[:alnum:]][-\w.+]*)}
  I18N_RE          = %r{[^[:alnum:]]}
  BINARY_ENCODINGS = %w(base64 8bit)
  ASCII_ENCODINGS  = %w(7bit quoted-printable)
  # :startdoc:

  private_constant :MEDIA_TYPE_RE, :I18N_RE, :BINARY_ENCODINGS,
    :ASCII_ENCODINGS

  # Builds a MIME::Type object from the +content_type+, a MIME Content Type
  # value (e.g., 'text/plain' or 'applicaton/x-eruby'). The constructed object
  # is yielded to an optional block for additional configuration, such as
  # associating extensions and encoding information.
  #
  # * When provided a Hash or a MIME::Type, the MIME::Type will be
  #   constructed with #init_with.
  # * When provided an Array, the MIME::Type will be constructed using
  #   the first element as the content type and the remaining flattened
  #   elements as extensions.
  # * Otherwise, the content_type will be used as a string.
  #
  # Yields the newly constructed +self+ object.
  def initialize(content_type) # :yields self:
    @friendly = {}
    self.obsolete = self.registered = false
    self.preferred_extension = self.docs = self.use_instead = nil
    self.extensions = []

    case content_type
    when Hash
      init_with(content_type)
    when Array
      self.content_type = content_type.shift
      self.extensions = content_type.flatten
    when MIME::Type
      init_with(content_type.to_h)
    else
      self.content_type = content_type
    end

    self.encoding ||= :default
    self.xrefs ||= {}

    yield self if block_given?
  end

  # Indicates that a MIME type is like another type. This differs from
  # <tt>==</tt> because <tt>x-</tt> prefixes are removed for this comparison.
  def like?(other)
    other = if other.respond_to?(:simplified)
              MIME::Type.simplified(other.simplified, remove_x_prefix: true)
            else
              MIME::Type.simplified(other.to_s, remove_x_prefix: true)
            end
    MIME::Type.simplified(simplified, remove_x_prefix: true) == other
  end

  # Compares the +other+ MIME::Type against the exact content type or the
  # simplified type (the simplified type will be used if comparing against
  # something that can be treated as a String with #to_s). In comparisons, this
  # is done against the lowercase version of the MIME::Type.
  def <=>(other)
    if other.nil?
      -1
    elsif other.respond_to?(:simplified)
      simplified <=> other.simplified
    else
      simplified <=> MIME::Type.simplified(other.to_s)
    end
  end

  # Compares the +other+ MIME::Type based on how reliable it is before doing a
  # normal <=> comparison. Used by MIME::Types#[] to sort types. The
  # comparisons involved are:
  #
  # 1. self.simplified <=> other.simplified (ensures that we
  #    don't try to compare different types)
  # 2. IANA-registered definitions < other definitions.
  # 3. Complete definitions < incomplete definitions.
  # 4. Current definitions < obsolete definitions.
  # 5. Obselete with use-instead names < obsolete without.
  # 6. Obsolete use-instead definitions are compared.
  #
  # While this method is public, its use is strongly discouraged by consumers
  # of mime-types. In mime-types 3, this method is likely to see substantial
  # revision and simplification to ensure current registered content types sort
  # before unregistered or obsolete content types.
  def priority_compare(other)
    pc = simplified <=> other.simplified
    if pc.zero?
      pc = if (reg = registered?) != other.registered?
             reg ? -1 : 1 # registered < unregistered
           elsif (comp = complete?) != other.complete?
             comp ? -1 : 1 # complete < incomplete
           elsif (obs = obsolete?) != other.obsolete?
             obs ? 1 : -1 # current < obsolete
           elsif obs and ((ui = use_instead) != (oui = other.use_instead))
             if ui.nil?
               1
             elsif oui.nil?
               -1
             else
               ui <=> oui
             end
           else
             0
           end
    end

    pc
  end

  # Returns +true+ if the +other+ object is a MIME::Type and the content types
  # match.
  def eql?(other)
    other.kind_of?(MIME::Type) and self == other
  end

  ##
  # :attr_reader: content_type
  #
  # Returns the whole MIME content-type string.
  #
  # The content type is a presentation value from the MIME type registry and
  # should not be used for comparison. The case of the content type is
  # preserved, and extension markers (<tt>x-</tt>) are kept.
  #
  #   text/plain        => text/plain
  #   x-chemical/x-pdb  => x-chemical/x-pdb
  #   audio/QCELP       => audio/QCELP
  attr_reader :content_type
  ##
  # :attr_reader: simplified
  #
  # A simplified form of the MIME content-type string, suitable for
  # case-insensitive comparison, with any extension markers (<tt>x-</tt)
  # removed and converted to lowercase.
  #
  #   text/plain        => text/plain
  #   x-chemical/x-pdb  => x-chemical/x-pdb
  #   audio/QCELP       => audio/qcelp
  pooled_accessor :simplified, private_writer: true
  ##
  # :attr_reader: media_type
  #
  # Returns the media type of the simplified MIME::Type.
  #
  #   text/plain        => text
  #   x-chemical/x-pdb  => x-chemical
  #   audio/QCELP       => audio
  pooled_accessor :media_type, private_writer: true
  ##
  # :attr_reader: raw_media_type
  #
  # Returns the media type of the unmodified MIME::Type.
  #
  #   text/plain        => text
  #   x-chemical/x-pdb  => x-chemical
  #   audio/QCELP       => audio
  pooled_accessor :raw_media_type, private_writer: true
  ##
  # :attr_reader: sub_type
  #
  # Returns the sub-type of the simplified MIME::Type.
  #
  #   text/plain        => plain
  #   x-chemical/x-pdb  => pdb
  #   audio/QCELP       => qcelp
  pooled_accessor :sub_type, private_writer: true
  ##
  # :attr_reader: :raw_sub_type
  #
  # Returns the media type of the unmodified MIME::Type.
  #
  #   text/plain        => plain
  #   x-chemical/x-pdb  => x-pdb
  #   audio/QCELP       => QCELP
  pooled_accessor :raw_sub_type, private_writer: true

  ##
  # The list of extensions which are known to be used for this MIME::Type.
  # Non-array values will be coerced into an array with #to_a. Array values
  # will be flattened, +nil+ values removed, and made unique.
  #
  # :attr_accessor: extensions
  def extensions
    @extensions.to_a
  end

  ##
  def extensions=(value) # :nodoc:
    value = Array(value).flatten.compact.map { |e| _vp_[e] }
    @extensions = Set[*value].freeze
    MIME::Types.send(:reindex_extensions, self)
    @extensions
  end

  # Uniquely merge one or more +extensions+ provided into this type.
  #
  #   text.add_extensions('txt') # => %w(txt asc c cc h hh cpp)
  def add_extensions(*extensions)
    self.extensions += extensions
    self.extensions
  end

  ##
  # The preferred extension for this MIME type. If one is not set and there are
  # exceptions defined, the first extension will be used.
  #
  # When setting #preferred_extensions, if #extensions does not contain this
  # extension, this will be added to #xtensions.
  #
  #   text.preferred_extension # => 'txt'
  #   text.preferred_extension = 'markdown' # => 'markdown'
  #   text.preferred_extension # => 'markdown'
  #
  # :attr_accessor: preferred_extension

  ##
  def preferred_extension
    @preferred_extension || extensions.first
  end

  ##
  def preferred_extension=(value) # :nodoc:
    add_extensions(value) if value
    @preferred_extension = _vp_[value]
  end

  ##
  # The encoding (+7bit+, +8bit+, <tt>quoted-printable</tt>, or +base64+)
  # required to transport the data of this content type safely across a
  # network, which roughly corresponds to Content-Transfer-Encoding. A value of
  # +nil+ or <tt>:default</tt> will reset the #encoding to the
  # #default_encoding for the MIME::Type. Raises ArgumentError if the encoding
  # provided is invalid.
  #
  # If the encoding is not provided on construction, this will be either
  # 'quoted-printable' (for text/* media types) and 'base64' for eveything
  # else.
  #
  # :attr_accessor: encoding

  ##
  attr_reader :encoding

  ##
  def encoding=(enc) # :nodoc:
    if enc.nil? or enc == :default
      @encoding = _vp_[default_encoding]
    elsif BINARY_ENCODINGS.include?(enc) or ASCII_ENCODINGS.include?(enc)
      @encoding = _vp_[enc]
    else
      fail InvalidEncoding, enc
    end
  end

  # Returns the default encoding for the MIME::Type based on the media type.
  def default_encoding
    @media_type == _vp_['text'] ? _vp_['quoted-printable'] : _vp_['base64']
  end

  ##
  # Returns the media type or types that should be used instead of this media
  # type, if it is obsolete. If there is no replacement media type, or it is
  # not obsolete, +nil+ will be returned.
  #
  # :attr_accessor: use_instead

  ##
  def use_instead
    obsolete? ? @use_instead : nil
  end

  pooled_writer :use_instead

  ##
  # :attr_accessor: obsolete
  # Returns +true+ if the media type is obsolete.
  pooled_accessor :obsolete
  alias :obsolete? :obsolete

  # The documentation for this MIME::Type.
  attr_accessor :docs

  # A friendly short description for this MIME::Type.
  #
  # call-seq:
  #   text_plain.friendly         # => "Text File"
  #   text_plain.friendly('en')   # => "Text File"
  def friendly(lang = 'en'.freeze)
    @friendly ||= {}

    case lang
    when String, Symbol
      @friendly[lang.to_s]
    when Array
      @friendly.update(Hash[*lang])
    when Hash
      @friendly.update(lang)
    else
      fail ArgumentError,
        "Expected a language or translation set, not #{lang.inspect}"
    end
  end

  ##
  # :attr_reader: i18n_key
  #
  # A key suitable for use as a lookup key for translations, such as with
  # the I18n library.
  #
  # call-seq:
  #    text_plain.i18n_key # => "text.plain"
  #    3gpp_xml.i18n_key   # => "application.vnd-3gpp-bsf-xml"
  #      # from application/vnd.3gpp.bsf+xml
  #    x_msword.i18n_key   # => "application.word"
  #      # from application/x-msword
  pooled_accessor :i18n_key, private_writer: true

  ##
  # The cross-references list for this MIME::Type.
  #
  # :attr_accessor: xrefs

  ##
  attr_reader :xrefs

  ##
  def xrefs=(x) # :nodoc:
    MIME::Types::Container.new.merge(x).tap do |xr|
      xr.each do |k, v|
        xr[k] = Set[*v.map { |e| _vp_[e] }] unless v.kind_of? Set
      end

      @xrefs = xr
    end
  end

  # The decoded cross-reference URL list for this MIME::Type.
  def xref_urls
    xrefs.flat_map { |type, values|
      name = :"xref_url_for_#{type.tr('-', '_')}"
      respond_to?(name, true) and xref_map(values, name) or values.to_a
    }
  end

  ##
  # :attr_accessor: registered
  #
  # Indicates whether the MIME type has been registered with IANA.
  pooled_accessor :registered
  alias :registered? :registered

  # MIME types can be specified to be sent across a network in particular
  # formats. This method returns +true+ when the MIME::Type encoding is set
  # to <tt>base64</tt>.
  def binary?
    BINARY_ENCODINGS.include?(encoding)
  end

  # MIME types can be specified to be sent across a network in particular
  # formats. This method returns +false+ when the MIME::Type encoding is
  # set to <tt>base64</tt>.
  def ascii?
    ASCII_ENCODINGS.include?(encoding)
  end

  ##
  # :attr_accessor: signature
  #
  # Indicates whether the MIME type is declared as a signature type.
  pooled_accessor :signature
  alias :signature? :signature

  # Returns +true+ if the MIME::Type specifies an extension list,
  # indicating that it is a complete MIME::Type.
  def complete?
    !@extensions.empty?
  end

  # Returns the MIME::Type as a string.
  def to_s
    content_type
  end

  # Returns the MIME::Type as a string for implicit conversions. This allows
  # MIME::Type objects to appear on either side of a comparison.
  #
  #   'text/plain' == MIME::Type.new('text/plain')
  def to_str
    content_type
  end

  # Returns a JSON string for the  MIME::Type as a JSON object.
  #
  # For compatibility with Rails JSON encoders, accepts and passes on any
  # +args+ provided.
  #
  #   text.to_json # => {"content-type":"text/plain",…}
  def to_json(*args)
    require 'json'
    to_h.to_json(*args)
  end

  # Converts the MIME::Type to a hash. The output of this method can also be
  # used to initialize a MIME::Type.
  def to_h
    encode_with({})
  end

  # Populates the +coder+ with attributes about this record for
  # serialization. The structure of +coder+ should match the structure used
  # with #init_with.
  #
  # This method should be considered a private implementation detail.
  def encode_with(coder)
    coder['content-type'] = content_type
    coder['docs'] = docs unless docs.nil? or docs.empty?
    coder['friendly'] = friendly unless friendly.nil? or friendly.empty?
    coder['encoding'] = encoding
    coder['extensions'] = extensions.to_a unless extensions.empty?
    coder['preferred-extension'] = preferred_extension if preferred_extension
    if obsolete?
      coder['obsolete'] = obsolete?
      coder['use-instead'] = use_instead if use_instead
    end
    unless xrefs.empty?
      {}.tap do |hash|
        xrefs.each { |k, v| hash[k] = v.sort.to_a }
        coder['xrefs'] = hash
      end
    end
    coder['registered'] = registered?
    coder['signature'] = signature? if signature?
    coder
  end

  # Initialize an empty object from +coder+, which must contain the
  # attributes necessary for initializing an empty object.
  #
  # This method should be considered a private implementation detail.
  def init_with(coder)
    self.content_type = coder['content-type']
    self.docs = coder['docs'] || ''
    self.encoding = coder['encoding']
    self.extensions = coder['extensions'] || []
    self.preferred_extension = coder['preferred-extension']
    self.obsolete = coder['obsolete'] || false
    self.registered = coder['registered'] || false
    self.signature = coder['signature']
    self.xrefs = coder['xrefs'] || {}
    self.use_instead = coder['use-instead']

    friendly(coder['friendly'] || {})
  end

  def inspect # :nodoc:
    # We are intentionally lying here because MIME::Type::Columnar is an
    # implementation detail.
    _vp_["#<MIME::Type: #{self}>"]
  end

  class << self
    # MIME media types are case-insensitive, but are typically presented in a
    # case-preserving format in the type registry.
    #
    # Returns the provided +content_type+ as a lowercase string, or +nil+ if
    # the content type is not valid.
    #
    # In previous versions of mime-types, this would also remove any extension
    # prefix (<tt>x-</tt>). This is no longer default behaviour, but may be
    # provided by providing a truth value to +remove_x_prefix+.
    #
    #   MIME::Type.simplified('text/_plain') # => nil
    #   MIME::Type.simplified('text/plain') # => 'text/plain'
    #   MIME::Type.simplified('text/Plain') # => 'text/plain'
    #   MIME::Type.simplified('text/x-Plain') # => 'text/x-plain'
    #   MIME::Type.simplified('text/x-Plain', remove_x_prefix: true) # => 'text/plain'
    def simplified(content_type, remove_x_prefix: false)
      if remove_x_prefix || content_type.kind_of?(MatchData)
        simplify_matchdata(match(content_type), remove_x_prefix)
      elsif content_type.match(MEDIA_TYPE_RE)
        content_type.downcase
      else
        nil
      end
    end

    # Returns the provided +content_type+ as a string translation key suitable
    # for use with the I18n library, or +nil+ if the content type is not valid.
    #
    #   MIME::Type.i18n_key('text/_plain') # => nil
    #   MIME::Type.i18n_key('text/plain') # => 'text.plain'
    #   MIME::Type.i18n_key('text/Plain') # => 'text.plain'
    #   MIME::Type.i18n_key('text/x-Plain') # => 'text.x-plain'
    def i18n_key(content_type)
      simplify_matchdata(match(content_type), joiner: '.'.freeze) { |e|
        e.gsub!(I18N_RE, '-'.freeze)
      }
    end

    # Return a +MatchData+ object of the +content_type+ against pattern of
    # media types, or +nil+ if the content type is not valid.
    #
    #   MIME::Type.match('text/_plain') # => nil
    #   MIME::Type.match('text/plain') # => <MatchData "text/plain" 1:"text" 2:"plain">
    #   MIME::Type.match('text/Plain')
    #     # => <MatchData "text/Plain" 1:"text" 2:"Plain">
    #   MIME::Type.match('text/x-Plain')
    #     # => <MatchData "text/x-Plain" 1:"text" 2:"x-Plain">
    def match(content_type)
      case content_type
      when MatchData
        content_type
      else
        content_type.match(MEDIA_TYPE_RE)
      end
    end

    private

    def simplify_matchdata(matchdata, remove_x = false, joiner: '/'.freeze)
      return nil unless matchdata

      matchdata.captures.map { |e|
        e.downcase!
        e.sub!(%r{^x-}, ''.freeze) if remove_x
        yield e if block_given?
        e
      }.join(joiner)
    end
  end

  private

  def content_type=(type_string)
    match = MIME::Type.match(type_string)
    fail InvalidContentType, type_string if match.nil?

    @content_type = _vp_[type_string]
    self.raw_media_type, self.raw_sub_type = match.captures
    self.simplified = type_string.downcase
    self.i18n_key = MIME::Type.i18n_key(match)
    self.media_type, self.sub_type = @simplified.split('/'.freeze)
  end

  def xref_map(values, helper)
    values.map { |value| send(helper, value) }
  end

  def xref_url_for_rfc(value)
    'http://www.iana.org/go/%s'.freeze % value
  end

  def xref_url_for_draft(value)
    'http://www.iana.org/go/%s'.freeze % value.sub(/\ARFC/, 'draft'.freeze)
  end

  def xref_url_for_rfc_errata(value)
    'http://www.rfc-editor.org/errata_search.php?eid=%s'.freeze % value
  end

  def xref_url_for_person(value)
    'http://www.iana.org/assignments/media-types/media-types.xhtml#%s'.freeze %
      value
  end

  def xref_url_for_template(value)
    'http://www.iana.org/assignments/media-types/%s'.freeze % value
  end

  def _vp_
    MIME::Type::ValuePool
  end
end
