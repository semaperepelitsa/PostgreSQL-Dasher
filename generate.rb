require 'set'
require 'pathname'
require 'sqlite3'
require 'fileutils'
require 'nokogiri'
require 'cgi'

source, = ARGV

unless source
  puts "Usage: ruby generate.rb PATH_TO_SOURCE_DIR"
  exit
end

source = Pathname(source)

unless source.directory?
  abort "Directory not found: #{source}"
end

resources = Pathname("postgresql.docset/Contents/Resources")
documents = resources.join("Documents")
database = resources.join("docSet.dsidx")
FileUtils.rm_r resources if resources.exist?

FileUtils.mkdir resources
FileUtils.mkdir documents
@db = SQLite3::Database.new(database.to_s)
@db.transaction do
  @db.execute <<-SQL
  CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT);
  SQL

  TYPES = {
    "functions" => "Function",
    "sql" => "Command",
    "queries" => "Command",
    "tutorial" => "Guide",
    "datatype" => "Type",
  }

  def idx_insert(name, type, path)
    @db.execute <<-SQL, [name, type, path]
    insert into searchIndex (name, type, path) values (?,?,?)
    SQL
  end

  typenames = Set.new

  Pathname.glob(source.join("*")).each do |path|
    relative_path = path.relative_path_from(source)
    basename = path.basename(".html")

    doc = Nokogiri::HTML(File.open(path.to_s))
    typename = basename.to_s[/^(\w+)\-/, 1]
    type = TYPES[typename]
    typenames << typename
    title = doc.xpath("string(/html/head/title)")
    up = doc.xpath("string(/html/head/link[@rel='UP']/@title)")

    case type
    when "Command", "Type", "Function"
      total = title
    else
      total = "#{title} — #{up}"
    end

    # p [basename, typename, type, doc.at_xpath("/html/body/h1")&.text]

    if type && title
      idx_insert(total, type, relative_path.to_s)
    end

    case typename
    when "functions", "datatype"
      doc.xpath("//table[@class='CALSTABLE']").each do |table|
        subtype = \
          case [typename, table.xpath("thead/tr/th[1]")&.text]
          when ["functions", "Function"]
            "Function"
          when ["functions", "Operator"]
            "Operator"
          when ["datatype", "Name"]
            "Type"
          else
            next
          end

        table.xpath("tbody/tr/td[1]").each do |element|
          name = element.text.gsub(/\n\s+/, "").strip
          anchor_name = "//apple_ref/cpp/#{subtype}/#{CGI.escape(name)}"
          idx_insert(name, subtype, "#{relative_path.to_s}##{anchor_name}")

          anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
          element.prepend_child(anchor)
        end
      end
    end

    case typename
    when "commands"
      doc.xpath("//div[@class='REFSECT2']/h3").each do |element|
        subtype = "Command"
        name = element.text.gsub(/\n\s+/, "").strip
        anchor_name = "//apple_ref/cpp/#{subtype}/#{CGI.escape(name).gsub("+", "%20")}"
        idx_insert("#{title} — #{name}", subtype, "#{relative_path.to_s}##{anchor_name}")
        # p [title, name]

        anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
        element.prepend_child(anchor)
      end
    end

    doc.xpath("//div[@class='REFSECT1' or @class='REFNAMEDIV']/h2").each do |element|
      subtype = "Section"
      name = element.text.gsub(/\n\s+/, "").strip
      anchor_name = "//apple_ref/cpp/#{subtype}/#{CGI.escape(name).gsub("+", "%20")}"
      # idx_insert("#{title} — #{name}", subtype, "#{relative_path.to_s}##{anchor_name}")
      # p [title, name]

      anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
      element.prepend_child(anchor)
    end

    File.write("#{documents}/#{path.basename}", doc.to_html)
  end
end

# puts typenames.to_a
