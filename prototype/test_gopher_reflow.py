import unittest

from gopher_reflow import parse_menu, reflow_text


class ReflowTests(unittest.TestCase):
    def assertJoined(self, text, fragment):
        self.assertIn(fragment, reflow_text(text).text)

    def test_wrapped_paragraph_and_short_final_line(self):
        source = (
            "The old road leads through the forest and eventually reaches\n"
            "a small village beside the river. Travellers usually stop here\n"
            "before continuing north.\n")
        self.assertEqual(
            reflow_text(source).text,
            "The old road leads through the forest and eventually reaches a small village beside the river. Travellers usually stop here before continuing north.\n")

    def test_blank_line_is_hard_boundary(self):
        source = "This is a sufficiently long first paragraph line with many words.\nLast line of it.\n\nNew paragraph here.\n"
        self.assertIn("\n\n", reflow_text(source).text)

    def test_table_is_preserved(self):
        source = "Name          Score\nAlice            10\nBob               8\n"
        self.assertEqual(reflow_text(source).text, source)

    def test_ascii_art_is_preserved(self):
        source = "+----------+\n|  HELLO   |\n+----------+\n"
        self.assertEqual(reflow_text(source).text, source)

    def test_short_verse_is_preserved(self):
        source = "I wandered alone\nUnder a pale moon\nHome was far away\n"
        self.assertEqual(reflow_text(source).text, source)

    def test_two_line_heading_does_not_invent_wrap_width(self):
        source = (
            " Temperature and Humidity Remote Tracking for Floodgap HQ Data Center\n"
            " updated every 10 minutes\n")
        self.assertEqual(reflow_text(source).text, source)

    def test_repeated_quote_prefix_can_reflow(self):
        source = (
            "> This quoted paragraph has enough words to approach the common width\n"
            "> and it continues naturally onto another long line of quoted prose\n"
            "> before ending here.\n")
        result = reflow_text(source).text
        self.assertNotIn("\n> and", result)

    def test_menu_parser_retains_destination(self):
        data = b"0Read me\t/docs/readme\texample.org\t70\r\n.\r\n"
        item = parse_menu(data)[0]
        self.assertEqual((item.item_type, item.selector, item.host, item.port),
                         ("0", "/docs/readme", "example.org", 70))


if __name__ == "__main__":
    unittest.main()
