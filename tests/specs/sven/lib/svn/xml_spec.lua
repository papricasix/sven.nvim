local xml = require("sven.lib.svn.xml")

describe("lib.svn.xml", function()
  describe("#parse", function()
    it("reads elements, attributes and text", function()
      local root = xml.parse([[
<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry
   revision="3">
<author>alice</author>
<msg>A message</msg>
</logentry>
<logentry revision="2"><author>someone</author></logentry>
</log>]])

      assert.are.same("#document", root.tag)

      local log = root:find("log")
      assert.is_not_nil(log)

      local entries = log:all("logentry")
      assert.are.same(2, #entries)
      assert.are.same("3", entries[1].attrs.revision)
      assert.are.same("3", entries[1]:attr("revision"))
      assert.are.same("alice", entries[1]:text_of("author"))
      assert.are.same("A message", entries[1]:text_of("msg"))
      assert.are.same("someone", entries[2]:text_of("author"))
      assert.is_nil(entries[2]:text_of("msg"))
    end)

    it("accepts a list of lines", function()
      local root = xml.parse { "<status>", '<target path=".">', "</target>", "</status>" }

      assert.are.same(".", root:path("status", "target").attrs.path)
    end)

    it("keeps newlines inside text", function()
      local root = xml.parse("<msg>first line\nsecond line\n\nfourth line</msg>")

      assert.are.same("first line\nsecond line\n\nfourth line", root:text_of("msg"))
    end)

    it("decodes entities in text and attributes", function()
      local root = xml.parse(
        [[<path name="a &amp; b &quot;c&quot; &lt;d&gt; &apos;e&apos;">x &lt; y &amp;&amp; y &gt; z &#65;&#x42;&#xE4;&#8364;</path>]]
      )
      local path = root:find("path")

      assert.are.same([[a & b "c" <d> 'e']], path.attrs.name)
      assert.are.same("x < y && y > z ABä€", path.text)
    end)

    it("leaves unknown entities alone", function()
      assert.are.same("a &unknown; b", xml.parse("<x>a &unknown; b</x>"):text_of("x"))
    end)

    it("handles self closing elements and single quoted attributes", function()
      local root = xml.parse([[<a><version side='source-left' kind="file"/><b/>text</a>]])
      local a = root:find("a")

      assert.are.same(2, #a.children)
      assert.are.same("source-left", a:find("version").attrs.side)
      assert.are.same("file", a:find("version").attrs.kind)
      assert.are.same("text", a.text)
    end)

    it("handles attributes that contain angle brackets and slashes", function()
      local root = xml.parse([[<entry path="dir/a>b.txt" url="file:///tmp/x"><name>n</name></entry>]])
      local entry = root:find("entry")

      assert.are.same("dir/a>b.txt", entry.attrs.path)
      assert.are.same("file:///tmp/x", entry.attrs.url)
      assert.are.same("n", entry:text_of("name"))
    end)

    it("skips declarations, comments and doctypes, and reads CDATA", function()
      local root = xml.parse([==[
<?xml version="1.0"?>
<!DOCTYPE note>
<!-- a comment with <tags> in it -->
<note><![CDATA[1 < 2 && <b>raw</b>]]></note>]==])

      assert.are.same(1, #root.children)
      assert.are.same("1 < 2 && <b>raw</b>", root:text_of("note"))
    end)

    it("finds descendants at any depth, in document order", function()
      local root = xml.parse([[
<log>
<logentry revision="5"><logentry revision="4"><logentry revision="3"/></logentry></logentry>
<logentry revision="2"/>
</log>]])

      local revisions = vim.tbl_map(function(entry)
        return entry.attrs.revision
      end, root:descendants("logentry"))

      assert.are.same({ "5", "4", "3", "2" }, revisions)
      assert.are.same(2, #root:find("log"):all("logentry"))
    end)

    it("returns nil for paths that do not exist", function()
      local root = xml.parse("<a><b/></a>")

      assert.is_not_nil(root:path("a", "b"))
      assert.is_nil(root:path("a", "c"))
      assert.is_nil(root:path("x", "b"))
    end)

    describe("with broken input", function()
      it("returns what could be read of a truncated document", function()
        local root = xml.parse([[<status><target path="."><entry path="a.txt"><wc-status item="modi]])

        local entry = root:path("status", "target", "entry")
        assert.is_not_nil(entry)
        assert.are.same("a.txt", entry.attrs.path)
        assert.are.same("modi", entry:find("wc-status").attrs.item)
      end)

      it("ignores end tags that were never opened", function()
        local root = xml.parse("<a></b><c>text</c></a>")

        assert.are.same("text", root:path("a", "c").text)
      end)

      it("closes elements that were left open by a parent's end tag", function()
        local root = xml.parse("<a><b><c>inner</a><d>after</d>")

        assert.are.same("inner", root:path("a", "b", "c").text)
        assert.are.same("after", root:text_of("d"))
      end)

      it("copes with empty input", function()
        assert.are.same(0, #xml.parse("").children)
        assert.are.same(0, #xml.parse({}).children)
      end)
    end)
  end)

  describe("#decode", function()
    it("returns strings without entities unchanged", function()
      assert.are.same("plain text", xml.decode("plain text"))
    end)

    it("decodes numeric entities to UTF-8", function()
      assert.are.same("\n", xml.decode("&#10;"))
      assert.are.same("ü", xml.decode("&#252;"))
      assert.are.same("😀", xml.decode("&#x1F600;"))
    end)
  end)
end)
