class DocsetGenerator
  require 'rubygems'
  require 'nokogiri'
  require 'fileutils'

  def parse_html_docref(node)
    code = ''
    code << node.xpath(".//p[@class='abstract']").text
    code << "\n"

    node_discussion = node.xpath(".//div[@class='api discussion']")
    node_cdesample  = node_discussion.xpath(".//div[@class='codesample clear']")
    node_cdesample.unlink

    code << node_discussion.text.sub(/^Discussion/, '')
    code.strip!
    code.gsub!(/^/m, '  # ')
    code << "\n"
    return code
  end

  def parse_type(type)
    if type.kind_of?(Array)
      type = type.first
    end
    type = type.to_s
    type.strip!
    star = type.sub!(/\s*\*$/, '') # Remove pointer star.
    case type
      when /\*$/
        # A double pointer, in MacRuby this becomes a Pointer.
        'Pointer'
      when /id(?:\s*<\w+>)?/
        'Object'
      when 'void'
        'nil'
      when 'SEL'
        'Symbol'
      when 'bool', 'BOOL'
        'Boolean'
      when 'float', 'double', 'CGFloat'
        'Float'
      when /(?:const\s+)?u?int(?:\d+_t)?/, 'char', 'unichar', 'short', 'long', 'long long', 'unsigned char', 'unsigned short', 'unsigned long', 'unsigned long long', 'NSInteger', 'NSUInteger'
        'Integer'
      when 'NSString', 'NSMutableString'
        'String'
      when 'NSArray', 'NSMutableArray'
        'Array'
      when 'NSDictionary', 'NSMutableDictionary'
        'Hash'
      else
        type
    end
  end

  def parse_html_method(doc, code = "")
    # Methods.
    methods = []
    methods.concat(doc.xpath("//div[@class='api classMethod']"))
    methods.concat(doc.xpath("//div[@class='api instanceMethod']"))
    methods.each do |node|
      decl = node.xpath(".//div[@class='declaration']").text
      types = decl.scan(/\(([^)]+)\)/)
      ret_type = types.shift

      # Docref.
      code << parse_html_docref(node)

      # Parameters and return value.
      arg_names = node.xpath(".//div[@class='api parameters']//dt")
      arg_docs = node.xpath(".//div[@class='api parameters']//dd")
      if arg_names.size == arg_docs.size
        has_types = types.size == arg_names.size
        arg_names.each_with_index do |arg_name, i|
          arg_doc = arg_docs[i]
          code << "  # @param "
          code << "[#{parse_type(types[i])}] " if has_types
          code << "#{arg_name.text} #{arg_doc.text}\n"
        end
      end
      retdoc = node.xpath(".//div[@class='return_value']/p").text.strip
      code << "  # @return "
      code << "[#{parse_type(ret_type)}] " if ret_type
      code << "#{retdoc}" unless retdoc.empty?
      code << "\n"

      is_class_method = decl.match(/^\s*\+/) != nil
      code << "  # @scope class\n" if is_class_method

      decl.sub!(/^\s*[\+\-]/, '') # Remove method qualifier.
      decl.sub!(/;\s*$/, '')

      no_break_space = [0x00A0].pack("U*")
      decl.gsub!(no_break_space, '')

      sel_parts = decl.gsub(/\([^)]+\)+/, '').split.map { |x| x.split(':') }
      head = sel_parts.shift
      code << "  def #{head[0]}("
      code << "#{head[1]}" if head.size > 1
      unless sel_parts.empty?
        code << ', '
        code << sel_parts.map { |part|
          if part[1]
            "#{part[0]}:#{part[1]}"
          else
            part[0]
          end
        }.join(', ')
      end
      code << "); end\n\n"
    end

    return code
  end

  def parse_html_class(name, doc)
    # Find superclass (mandatory).
    sclass = nil
    doc.xpath("//table[@class='specbox']/tr").each do |node|
      if md = node.text.match(/Inherits from([^ ]+)/)
        sclass = md[1]
        break
      end
    end
    return nil unless sclass

    code = ''

    # Determine where the class is defined (optional).
    elem = doc.xpath(".//span[@class='FrameworkPath']")
    if elem.size > 0
      framework_path = elem[0].parent.parent.parent.children[1].text
      code << "# -*- framework: #{framework_path} -*-\n\n"
    else
      $stderr.puts "Can't determine framework path for: #{name}"
      code << "\n\n"
    end

    # Class abstract.
    code << doc.xpath(".//p[@class='abstract']")[0].text.gsub(/^/m, '# ')
    if sclass == "none"
      code << "\nclass #{name}\n\n"
    else
      code << "\nclass #{name} < #{sclass}\n\n"
    end

    # Properties.
    doc.xpath("//div[@class='api propertyObjC']").each do |node|
      decl = node.xpath(".//div[@class='declaration']/div[@class='declaration']").text
      readonly = decl.include?('readonly')
      decl.sub!(/@property\s*(\([^\)]+\))?/, '')
      md = decl.match(/(\w+)$/)
      next unless md
      title = md[1]
      type = md.pre_match

      code << parse_html_docref(node)
      code << "  # @return [#{parse_type(type)}]\n"
      code << '  ' << (readonly ? "attr_reader" : "attr_accessor") << " :#{title}\n\n"
    end

    parse_html_method(doc, code)

    code << "end"
    return code
  end

  def parse_html_struct(doc, code = "")
    node_name        = doc.xpath("../h3[@class='tight jump struct']")
    node_abstract    = doc.xpath("../p[@class='abstract']")
    node_declaration = doc.xpath("../pre[@class='declaration']")
    node_termdef     = doc.xpath("../dl[@class='termdef']")

    node_name.size.times do |i|
      name        = node_name[i].text
      abstract    = node_abstract[i].text
      declaration = node_declaration[i].text.strip
      members     = declaration.lines.to_a[1..-1] # cut 'struct CGPoint {' line
      unless members.empty?
        code << "# #{abstract}\n"
        code << "class #{name} < Boxed\n"

        node_field_description = node_termdef.xpath("dd")
        members.each_with_index do |item, index|
          break if item =~ /\}/
          item =~ /(.+)\s+(.+);/
          type   = $1
          member = $2
          code << "  # @return [#{parse_type(type)}] #{node_field_description[index].text}\n"
          code << "  attr_accessor :#{member}\n"
        end
        code << "end\n\n"
      end
    end

    code
  end

  def parse_html_reference(name, doc)
    if node = doc.xpath("//section/a[@title='Data Types']")
      parse_html_struct(node)
    end
  end

  def parse_html_data(data)
    doc = Nokogiri::HTML(data)
    title = doc.xpath('/html/head/title')
    if title
      if md = title.text.match(/^(.+)Class Reference$/)
        parse_html_class(md[1].strip, doc)
      elsif md = title.text.match(/^(.+) Reference$/)
        parse_html_reference(md[1].strip, doc)
      end
    else
      nil
    end
  end

  def initialize(outpath, paths)
    @input_paths = []
    paths.each do |path|
      path = File.expand_path(path)
      if File.directory?(path)
        @input_paths.concat(Dir.glob(path + '/**/*.html'))
      else
        @input_paths << path
      end
    end
    @outpath = outpath
    @rb_files_dir = '/tmp/rb_docset'
  end

  def generate_ruby_code
    FileUtils.rm_rf(@rb_files_dir)
    FileUtils.mkdir_p(@rb_files_dir)

    @input_paths.map { |path| parse_html_data(File.read(path)) }.compact.each_with_index do |code, n|
      File.open(File.join(@rb_files_dir, "t#{n}.rb"), 'w') do |io|
        io.puts "# -*- coding: utf-8 -*-"
        io.write(code)
      end
    end
  end

  def generate_html
    sh "yard doc #{@rb_files_dir}"
    sh "mv doc \"#{@outpath}\""
  end

  def run
    generate_ruby_code()
    generate_html()
  end
end
