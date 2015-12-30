require 'set'
require 'pathname'
require 'sqlite3'
require 'fileutils'
require 'nokogiri'
require 'cgi'

source, = ARGV

unless source
  puts "Usage: ruby generate.rb /usr/local/share/doc/postgresql/html"
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

def idx_insert(name, type, path)
  @db.execute <<-SQL, [name, type, path]
  insert into searchIndex (name, type, path) values (?,?,?)
  SQL
end

def url_escape(raw)
  CGI.escape(raw).gsub("+", "%20")
end

def apple_ref(type, name)
  "//apple_ref/cpp/#{type}/#{url_escape(name)}"
end

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
    "app" => "Service",
  }

  Pathname.glob(source.join("*")).each do |path|
    relative_path = path.relative_path_from(source)
    basename = path.basename(".html")

    doc = Nokogiri::HTML(File.open(path.to_s))
    typename = basename.to_s[/^(\w+)\-/, 1]
    type = TYPES[typename] || "Guide"
    title = doc.xpath("string(/html/head/title)")
    h1 = doc.xpath("string(//h1[@class='SECT1'])")
    up = doc.xpath("string(/html/head/link[@rel='UP']/@title)")

    if up == "Additional Supplied Modules"
      type = "Module"
    end

    # Guides have ambiguous titles
    case type
    when "Guide"
      total = "#{h1} — #{up}" unless h1.empty?
    else
      total = title
    end

    # Index whole page
    if type && total
      idx_insert(total, type, relative_path.to_s)
    end

    # Index tables inside page
    case type
    when "Function", "Type", "Module"
      doc.xpath("//table[@class='CALSTABLE']").each do |table|
        heading = table.xpath("string(thead/tr/th[1])")
        subtype = \
          case
          when heading == "Function"
            "Function"
          when heading == "Operator"
            "Operator"
          when heading == "Name" && type == "Type"
            "Type"
          else
            next
          end

        table.xpath("tbody/tr/td[1]").each do |element|
          name = element.text.gsub(/\n\s+/, "").strip
          anchor_name = apple_ref(subtype, name)

          case subtype
          when "Operator"
            fullname = "#{title.sub(/(Functions and )?Operators/, "").strip}: #{name}"
          else
            fullname = name
          end

          idx_insert(fullname, subtype, "#{relative_path.to_s}##{anchor_name}")

          anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
          element.prepend_child(anchor)
        end
      end
    end

    # Index keywords in sections, such as SELECT — WHERE.
    case
    when type != "Module" && type != "Type"
      doc.css("div > h2 tt, div > h3 tt").each do |element|
        subtype = type
        name = element.text.gsub(/\n\s+/, "").strip
        anchor_name = apple_ref(subtype, name)

        case type
        when "Function"
          subtitle = name
        else
          subtitle = "#{title} — #{name}"
        end

        idx_insert(subtitle, subtype, "#{relative_path.to_s}##{anchor_name}")

        anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
        element.prepend_child(anchor)
      end
    end

    # Add general sections to tables of content.
    # Index section if it contains a function.
    doc.xpath("//div[@class='REFSECT1' or @class='REFNAMEDIV' or @class='SECT2' or @class='SECT1']/*[self::h2 or self::h1]").each do |element|
      subtype = "Section"
      name = element.text.gsub(/\n\s+/, "").strip
      anchor_name = apple_ref(subtype, name)

      fn = element.at_xpath(".//code[@class='FUNCTION']")
      if fn && ["Command", "Function"].include?(type)
        idx_insert(fn.text, "Function", "#{relative_path.to_s}##{anchor_name}")
      end

      anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
      element.prepend_child(anchor)
    end

    # Index config variables.
    case
    when basename.to_s.start_with?("runtime-config") || basename.to_s.include?("settings")
      doc.css("div > div.VARIABLELIST > dl > dt > tt.VARNAME").each do |element|
        subtype = "Variable"
        name = element.text.gsub(/\n\s+/, "").strip
        anchor_name = apple_ref(subtype, name)
        idx_insert(name, subtype, "#{relative_path.to_s}##{anchor_name}")

        anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
        element.prepend_child(anchor)
      end
    end

    File.write("#{documents}/#{path.basename}", doc.to_html)
  end
end
