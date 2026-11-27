import unittest
from html import escape

from render_corpus_html import render_document


class HtmlRenderingTests(unittest.TestCase):
    def test_justified_prose_keeps_short_final_line_in_paragraph(self):
        result = render_document(
            "The old road  leads through the forest and eventually reaches\n"
            "a small  village beside the river.  Travellers usually stop here\n"
            "before continuing north."
        )
        self.assertEqual(
            result,
            "<p>The old road leads through the forest and eventually reaches "
            "a small village beside the river. Travellers usually stop here "
            "before continuing north.</p>",
        )

    def test_real_columns_keep_spacing_and_header(self):
        table = (
            "City           Low    High\n\n"
            "Oslo            -3       5\n"
            "Rome            12      19\n"
            "London           9      14"
        )
        self.assertEqual(render_document(table), f'<pre tabindex="0">\n{table}</pre>')

    def test_sparse_outline_stays_with_drawing(self):
        picture = "   .-------\n .'         '.\n|  @@@  @@@   |\n|     \\/      |\n `-._     _.-'\n     `---'"
        self.assertEqual(render_document(picture), f'<pre tabindex="0">\n{escape(picture)}</pre>')

    def test_ornaments_keep_their_characters_and_spacing(self):
        banner = "**************************\n**     Hello there!     **\n**     Welcome back     **\n**************************"
        result = render_document(f"Example\n=======\n\n{banner}\n\n  -----")
        self.assertEqual(result, f'<h2>Example</h2>\n<pre tabindex="0">\n{banner}</pre>\n'
                                 '<pre tabindex="0">\n  -----</pre>')

    def test_indented_urls_and_dates_are_reading_content(self):
        result = render_document("\thttps://example.org/\n\n* 2026-11-26\tUpdated the archive.")
        self.assertEqual(result, "<p>https://example.org/</p>\n<ul><li>2026-11-26 Updated the archive.</li></ul>")

    def test_source_snippet_is_escaped_and_preformatted(self):
        result = render_document("An example follows.\n\n<HTML>\n\n  <TITLE>Hello</TITLE>\n</HTML>")
        self.assertIn("<p>An example follows.</p>", result)
        self.assertIn('<pre tabindex="0">\n&lt;HTML&gt;\n\n  &lt;TITLE&gt;Hello&lt;/TITLE&gt;', result)

    def test_verse_keeps_line_breaks(self):
        self.assertEqual(render_document("I wandered alone\nunder a pale moon\nfar from home"),
                         "<p>I wandered alone<br>\nunder a pale moon<br>\nfar from home</p>")


if __name__ == "__main__":
    unittest.main()
