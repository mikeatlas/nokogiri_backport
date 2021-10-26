# coding: utf-8
# frozen_string_literal: true

require "pathname"

module Nokogiri
  module XML
    # Nokogiri::XML::Document is the main entry point for dealing with XML documents.  The Document
    # is created by parsing an XML document.  See Nokogiri::XML::Document.parse for more information
    # on parsing.
    #
    # For searching a Document, see Nokogiri::XML::Searchable#css and
    # Nokogiri::XML::Searchable#xpath
    class Document < Nokogiri::XML::Node
      # See http://www.w3.org/TR/REC-xml-names/#ns-decl for more details. Note that we're not
      # attempting to handle unicode characters partly because libxml2 doesn't handle unicode
      # characters in NCNAMEs.
      NCNAME_START_CHAR = "A-Za-z_"
      NCNAME_CHAR       = NCNAME_START_CHAR + "\\-\\.0-9"
      NCNAME_RE         = /^xmlns(?::([#{NCNAME_START_CHAR}][#{NCNAME_CHAR}]*))?$/

      ##
      # Parse an XML file.
      #
      # +string_or_io+ may be a String, or any object that responds to
      # _read_ and _close_ such as an IO, or StringIO.
      #
      # +url+ (optional) is the URI where this document is located.
      #
      # +encoding+ (optional) is the encoding that should be used when processing
      # the document.
      #
      # +options+ (optional) is a configuration object that sets options during
      # parsing, such as Nokogiri::XML::ParseOptions::RECOVER. See the
      # Nokogiri::XML::ParseOptions for more information.
      #
      # +block+ (optional) is passed a configuration object on which
      # parse options may be set.
      #
      # By default, Nokogiri treats documents as untrusted, and so
      # does not attempt to load DTDs or access the network. See
      # Nokogiri::XML::ParseOptions for a complete list of options;
      # and that module's DEFAULT_XML constant for what's set (and not
      # set) by default.
      #
      # Nokogiri.XML() is a convenience method which will call this method.
      #
      def self.parse(string_or_io, url = nil, encoding = nil, options = ParseOptions::DEFAULT_XML)
        options = Nokogiri::XML::ParseOptions.new(options) if Integer === options

        yield options if block_given?

        url ||= string_or_io.respond_to?(:path) ? string_or_io.path : nil

        if empty_doc?(string_or_io)
          if options.strict?
            raise Nokogiri::XML::SyntaxError.new("Empty document")
          else
            return encoding ? new.tap { |i| i.encoding = encoding } : new
          end
        end

        doc = if string_or_io.respond_to?(:read)
          if string_or_io.is_a?(Pathname)
            # resolve the Pathname to the file and open it as an IO object, see #2110
            string_or_io = string_or_io.expand_path.open
            url ||= string_or_io.path
          end

          read_io(string_or_io, url, encoding, options.to_i)
        else
          # read_memory pukes on empty docs
          read_memory(string_or_io, url, encoding, options.to_i)
        end

        # do xinclude processing
        doc.do_xinclude(options) if options.xinclude?

        return doc
      end

      ##
      # :singleton-method: wrap
      # :call-seq: wrap(java_document) → Nokogiri::XML::Document
      #
      # ⚠ This method is only available when running JRuby.
      #
      # Create a Document using an existing Java DOM document object.
      #
      # The returned Document shares the same underlying data structure as the Java object, so
      # changes in one are reflected in the other.
      #
      # [Parameters]
      # - `java_document` (Java::OrgW3cDom::Document)
      #   (The class `Java::OrgW3cDom::Document` is also accessible as `org.w3c.dom.Document`.)
      #
      # [Returns] Nokogiri::XML::Document
      #
      # See also \#to_java

      # :method: to_java
      # :call-seq: to_java() → Java::OrgW3cDom::Document
      #
      # ⚠ This method is only available when running JRuby.
      #
      # Returns the underlying Java DOM document object for this document.
      #
      # The returned Java object shares the same underlying data structure as this document, so
      # changes in one are reflected in the other.
      #
      # [Returns]
      #   Java::OrgW3cDom::Document
      #   (The class `Java::OrgW3cDom::Document` is also accessible as `org.w3c.dom.Document`.)
      #
      # See also Document.wrap

      # The errors found while parsing a document.
      #
      # [Returns] Array<Nokogiri::XML::SyntaxError>
      attr_accessor :errors

      # When `true`, reparented elements without a namespace will inherit their new parent's
      # namespace (if one exists). Defaults to `false`.
      #
      # [Returns] Boolean
      #
      # *Example:* Default behavior of namespace inheritance
      #
      #   xml = <<~EOF
      #           <root xmlns:foo="http://nokogiri.org/default_ns/test/foo">
      #             <foo:parent>
      #             </foo:parent>
      #           </root>
      #         EOF
      #   doc = Nokogiri::XML(xml)
      #   parent = doc.at_xpath("//foo:parent", "foo" => "http://nokogiri.org/default_ns/test/foo")
      #   parent.add_child("<child></child>")
      #   doc.to_xml
      #   # => <?xml version="1.0"?>
      #   #    <root xmlns:foo="http://nokogiri.org/default_ns/test/foo">
      #   #      <foo:parent>
      #   #        <child/>
      #   #      </foo:parent>
      #   #    </root>
      #
      # *Example:* Setting namespace inheritance to `true`
      #
      #   xml = <<~EOF
      #           <root xmlns:foo="http://nokogiri.org/default_ns/test/foo">
      #             <foo:parent>
      #             </foo:parent>
      #           </root>
      #         EOF
      #   doc = Nokogiri::XML(xml)
      #   doc.namespace_inheritance = true
      #   parent = doc.at_xpath("//foo:parent", "foo" => "http://nokogiri.org/default_ns/test/foo")
      #   parent.add_child("<child></child>")
      #   doc.to_xml
      #   # => <?xml version="1.0"?>
      #   #    <root xmlns:foo="http://nokogiri.org/default_ns/test/foo">
      #   #      <foo:parent>
      #   #        <foo:child/>
      #   #      </foo:parent>
      #   #    </root>
      #
      # Since v1.12.4
      attr_accessor :namespace_inheritance

      def initialize(*args) # :nodoc:
        @errors     = []
        @decorators = nil
        @namespace_inheritance = false
      end

      # :call-seq:
      #   create_element(name, *contents_or_attrs, &block) → Nokogiri::XML::Element
      #
      # Create a new Element with `name` belonging to this document, optionally setting contents or
      # attributes.
      #
      # This method is _not_ the most user-friendly option if your intention is to add a node to the
      # document tree. Prefer one of the Nokogiri::XML::Node methods like Node#add_child,
      # Node#add_next_sibling, Node#replace, etc. which will both create an element (or subtree) and
      # place it in the document tree.
      #
      # Arguments may be passed to initialize the element:
      #
      # - a Hash argument will be used to set attributes
      # - a non-Hash object that responds to \#to_s will be used to set the new node's contents
      #
      # A block may be passed to mutate the node.
      #
      # [Parameters]
      # - `name` (String)
      # - `contents_or_attrs` (\#to_s, Hash)
      # [Yields] `node` (Nokogiri::XML::Element)
      # [Returns] Nokogiri::XML::Element
      #
      # *Example:* An empty element without attributes
      #
      #   doc.create_element("div")
      #   # => <div></div>
      #
      # *Example:* An element with contents
      #
      #   doc.create_element("div", "contents")
      #   # => <div>contents</div>
      #
      # *Example:* An element with attributes
      #
      #   doc.create_element("div", {"class" => "container"})
      #   # => <div class='container'></div>
      #
      # *Example:* An element with contents and attributes
      #
      #   doc.create_element("div", "contents", {"class" => "container"})
      #   # => <div class='container'>contents</div>
      #
      # *Example:* Passing a block to mutate the element
      #
      #   doc.create_element("div") { |node| node["class"] = "blue" if before_noon? }
      #
      def create_element(name, *contents_or_attrs, &block)
        elm = Nokogiri::XML::Element.new(name, self, &block)
        contents_or_attrs.each do |arg|
          case arg
          when Hash
            arg.each do |k, v|
              key = k.to_s
              if key =~ NCNAME_RE
                ns_name = Regexp.last_match(1)
                elm.add_namespace_definition(ns_name, v)
              else
                elm[k.to_s] = v.to_s
              end
            end
          else
            elm.content = arg
          end
        end
        if ns = elm.namespace_definitions.find { |n| n.prefix.nil? || (n.prefix == "") }
          elm.namespace = ns
        end
        elm
      end

      # Create a Text Node with +string+
      def create_text_node(string, &block)
        Nokogiri::XML::Text.new(string.to_s, self, &block)
      end

      # Create a CDATA Node containing +string+
      def create_cdata(string, &block)
        Nokogiri::XML::CDATA.new(self, string.to_s, &block)
      end

      # Create a Comment Node containing +string+
      def create_comment(string, &block)
        Nokogiri::XML::Comment.new(self, string.to_s, &block)
      end

      # The name of this document.  Always returns "document"
      def name
        "document"
      end

      # A reference to +self+
      def document
        self
      end

      # :call-seq:
      #   collect_namespaces() → Hash<String(Namespace#prefix) ⇒ String(Namespace#href)>
      #
      # Recursively get all namespaces from this node and its subtree and return them as a
      # hash.
      #
      # ⚠ This method will not handle duplicate namespace prefixes, since the return value is a hash.
      #
      # Note that this method does an xpath lookup for nodes with namespaces, and as a result the
      # order (and which duplicate prefix "wins") may be dependent on the implementation of the
      # underlying XML library.
      #
      # *Example:* Basic usage
      #
      # Given this document:
      #
      #   <root xmlns="default" xmlns:foo="bar">
      #     <bar xmlns:hello="world" />
      #   </root>
      #
      # This method will return:
      #
      #   {"xmlns:foo"=>"bar", "xmlns"=>"default", "xmlns:hello"=>"world"}
      #
      # *Example:* Duplicate prefixes
      #
      # Given this document:
      #
      #   <root xmlns:foo="bar">
      #     <bar xmlns:foo="baz" />
      #   </root>
      #
      # The hash returned will be something like:
      #
      #   {"xmlns:foo" => "baz"}
      #
      def collect_namespaces
        xpath("//namespace::*").inject({}) do |hash, ns|
          hash[["xmlns", ns.prefix].compact.join(":")] = ns.href if ns.prefix != "xml"
          hash
        end
      end

      # Get the list of decorators given +key+
      def decorators(key)
        @decorators ||= {}
        @decorators[key] ||= []
      end

      ##
      # Validate this Document against it's DTD.  Returns a list of errors on
      # the document or +nil+ when there is no DTD.
      def validate
        return nil unless internal_subset
        internal_subset.validate(self)
      end

      ##
      # Explore a document with shortcut methods. See Nokogiri::Slop for details.
      #
      # Note that any nodes that have been instantiated before #slop!
      # is called will not be decorated with sloppy behavior. So, if you're in
      # irb, the preferred idiom is:
      #
      #   irb> doc = Nokogiri::Slop my_markup
      #
      # and not
      #
      #   irb> doc = Nokogiri::HTML my_markup
      #   ... followed by irb's implicit inspect (and therefore instantiation of every node) ...
      #   irb> doc.slop!
      #   ... which does absolutely nothing.
      #
      def slop!
        unless decorators(XML::Node).include?(Nokogiri::Decorators::Slop)
          decorators(XML::Node) << Nokogiri::Decorators::Slop
          decorate!
        end

        self
      end

      ##
      # Apply any decorators to +node+
      def decorate(node)
        return unless @decorators
        @decorators.each do |klass, list|
          next unless node.is_a?(klass)
          list.each { |moodule| node.extend(moodule) }
        end
      end

      alias_method :to_xml, :serialize
      alias_method :clone, :dup

      # Get the hash of namespaces on the root Nokogiri::XML::Node
      def namespaces
        root ? root.namespaces : {}
      end

      ##
      # Create a Nokogiri::XML::DocumentFragment from +tags+
      # Returns an empty fragment if +tags+ is nil.
      def fragment(tags = nil)
        DocumentFragment.new(self, tags, self.root)
      end

      undef_method :swap, :parent, :namespace, :default_namespace=
      undef_method :add_namespace_definition, :attributes
      undef_method :namespace_definitions, :line, :add_namespace

      def add_child(node_or_tags)
        raise "A document may not have multiple root nodes." if (root && root.name != "nokogiri_text_wrapper") && !(node_or_tags.comment? || node_or_tags.processing_instruction?)
        node_or_tags = coerce(node_or_tags)
        if node_or_tags.is_a?(XML::NodeSet)
          raise "A document may not have multiple root nodes." if node_or_tags.size > 1
          super(node_or_tags.first)
        else
          super
        end
      end
      alias_method :<<, :add_child

      private

      def self.empty_doc?(string_or_io)
        string_or_io.nil? ||
          (string_or_io.respond_to?(:empty?) && string_or_io.empty?) ||
          (string_or_io.respond_to?(:eof?) && string_or_io.eof?)
      end

      IMPLIED_XPATH_CONTEXTS = ["//".freeze].freeze # :nodoc:

      def inspect_attributes
        [:name, :children]
      end
    end
  end
end
