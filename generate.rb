require 'set'
require 'pathname'
require 'sqlite3'
require 'fileutils'
require 'nokogiri'
require 'cgi'

root = "postgresql.docset/Contents"
documents = "#{root}/Resources/Documents"
@db = SQLite3::Database.new "#{root}/Resources/docSet.dsidx"

@db.execute <<-SQL
DROP TABLE IF EXISTS searchIndex;
SQL

@db.execute <<-SQL
CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT);
SQL

FileUtils.rm Dir["#{documents}/*"]

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

Pathname.glob("html/*").each do |path|
  relative_path = path.relative_path_from(Pathname("html"))
  basename = path.basename(".html")

  doc = Nokogiri::HTML(File.open(path.to_s))
  typename = basename.to_s[/^(\w+)\-/, 1]
  type = TYPES[typename]
  typenames << typename
  title = doc.at_xpath("/html/head/title")&.text

  # p [basename, typename, type, doc.at_xpath("/html/body/h1")&.text]

  if type && title
    idx_insert(title, type, relative_path.to_s)
  end

  case typename
  when "functions"
    doc.xpath("//table[@class='CALSTABLE']").each do |table|
      fn_type = \
        case table.xpath("thead/tr/th[1]")&.text
        when "Function"
          "Function"
        when "Operator"
          "Operator"
        else
          next
        end

      table.xpath("tbody/tr/td[1]").each do |fn|
        name = fn.text.gsub(/\n\s+/, "").strip
        p [fn_type, name]
        anchor_name = "//apple_ref/cpp/Function/#{CGI.escape(name)}"
        idx_insert(name, fn_type, "#{relative_path.to_s}##{anchor_name}")

        anchor = doc.create_element("a", name: anchor_name, class: "dashAnchor")
        fn.prepend_child(anchor)
      end
    end
  end

  File.write("#{documents}/#{path.basename}", doc.to_html)
end

# puts typenames.to_a
