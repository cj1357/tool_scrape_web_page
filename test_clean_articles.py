import csv
import json
import re
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from clean_articles import (
    extract_ad_topic,
    extract_article,
    generate_term_items,
    load_pages,
    load_source_tables,
)


class TermGenerationTests(unittest.TestCase):
    def test_extracts_english_topics_without_call_to_action_words(self) -> None:
        cases = {
            "See more info about AI Helpdesk. See more info about AI Helpdesk": "ai helpdesk",
            "Learn More Here. Learn more about AI Application Security": "ai application security",
            "Learn more here. Explore more about SME Phone Packages": "sme phone packages",
        }
        for ad_content, expected in cases.items():
            with self.subTest(ad_content=ad_content):
                self.assertEqual(extract_ad_topic(ad_content), expected)

    def test_extracts_german_topics_without_call_to_action_words(self) -> None:
        cases = {
            "Mehr erfahren. Erfahren Sie mehr uber KI Automatisierung": "ki automatisierung",
            "Mehr erfahren. Weitere Informationen finden Sie unter Flughafenbetrieb": "flughafenbetrieb",
            "Erfahre mehr hier. Beginne mehr uber Zugangskontrollsystem zu lernen": "zugangskontrollsystem",
            "Mehr erfahren. Lesen Sie mehr uber medizinische Software 2026": "medizinische software 2026",
        }
        for ad_content, expected in cases.items():
            with self.subTest(ad_content=ad_content):
                self.assertEqual(extract_ad_topic(ad_content), expected)

    def test_sme_phone_terms_follow_competitor_style(self) -> None:
        items = generate_term_items(
            ["Learn more. Hurry, Learn more about sme phone packages on the site."],
            ["SME Phone Packages 2026: 5 Rock-Bottom Plans Under $15 That Still Work - InfoQo"],
            "en",
        )
        self.assertEqual(
            items,
            [
                "sme phone packages 2026",
                "best phone systems 2026",
                "smb phone package",
                "phone packages for smb",
                "phone packages for smb for you 2026",
            ],
        )

    def test_generated_terms_never_repeat_cta_phrases(self) -> None:
        items = generate_term_items(
            ["Mehr hier erfahren. Erfahren Sie etwas uber E Mail Marketing fur Neukunden"],
            ["Erfahren Sie mehr über E-Mail Marketing für Neukunden: Ihr Weg zum Erfolg"],
            "de",
        )
        term = " ".join(items)
        for noise in ("mehr hier erfahren", "erfahren sie etwas", "learn more", "read more"):
            self.assertNotIn(noise, term)
        self.assertGreaterEqual(len(items), 4)
        self.assertLessEqual(len(items), 6)

    def test_how_to_variants_do_not_prepend_how_to_to_a_noun_phrase(self) -> None:
        items = generate_term_items(
            ["Learn more here. learn about application security posture"],
            ["How to Get Powerful Insights on Application Security"],
            "en",
        )
        self.assertNotIn("how to application security posture", items)

        home_business_items = generate_term_items(
            ["Learn more here. learn about Want Start Business from Home"],
            ["Want To Start A Business From Home? Simple Insights To Get You Going"],
            "en",
        )
        self.assertNotIn("how to want start business from home", home_business_items)

    def test_german_variants_drop_articles_and_only_use_wie_man_for_actions(self) -> None:
        remote_items = generate_term_items(
            ["Erfahren Sie hier mehr. lernen Sie Allgemeines Wissen über die Fernverwaltung von KI"],
            ["Fernverwaltung von KI: Ein einfacher Wegweiser für alle"],
            "de",
        )
        self.assertTrue(all("beste die " not in item for item in remote_items))

        medical_items = generate_term_items(
            ["Mehr erfahren. Lesen Sie mehr uber medizinische Software 2026"],
            ["Medizinische Software 2026 entdecken: Wie smarte Technik deine Gesundheit schützt"],
            "de",
        )
        self.assertNotIn("wie man medizinische software 2026", medical_items)


class ArticleStructureTests(unittest.TestCase):
    def test_recovers_heading_paragraph_moved_out_of_invalid_h2(self) -> None:
        root = Path(__file__).resolve().parent
        valid_pages, _ = load_pages(root, load_source_tables(root))
        page = next(
            page
            for page in valid_pages
            if "SME Phone Packages 2026: 5 Rock-Bottom Plans" in page.text
        )
        with TemporaryDirectory() as temporary_directory:
            article = extract_article(page, "heading-recovery-test", Path(temporary_directory))

        block = next(
            block
            for block in article["content_blocks"]
            if block.get("text") == "Best Phone Systems 2026: Cheapest Winners for Small Teams"
        )
        self.assertEqual(block["type"], "heading")
        self.assertEqual(block["level"], 2)

    def test_cleaned_lp_titles_do_not_keep_question_marks_inside_words(self) -> None:
        root = Path(__file__).resolve().parent
        articles = json.loads(
            (root / "cleaned_data" / "articles.json").read_text(encoding="utf-8")
        )
        damaged = [
            title
            for article in articles
            for title in article["lp_titles"]
            if re.search(r"\w\?\w", title)
        ]
        self.assertEqual(damaged, [])


class GeneratedDataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = Path(__file__).resolve().parent / "cleaned_data"
        cls.articles = json.loads((cls.root / "articles.json").read_text(encoding="utf-8"))
        cls.manifest = json.loads((cls.root / "manifest.json").read_text(encoding="utf-8"))

    def test_public_article_schema_excludes_private_fields(self) -> None:
        expected_fields = {
            "id",
            "slug",
            "title",
            "published_at",
            "read_minutes",
            "language",
            "locale",
            "locations",
            "ad_contents",
            "lp_titles",
            "term",
            "term_items",
            "excerpt",
            "content_blocks",
        }
        forbidden_fields = {"content_html", "sources", "content_hash"}
        for article in self.articles:
            self.assertEqual(set(article), expected_fields)
            serialized = json.dumps(article, ensure_ascii=False)
            for field in forbidden_fields:
                self.assertNotIn(f'"{field}"', serialized)

    def test_master_and_individual_articles_match(self) -> None:
        individual_paths = sorted((self.root / "articles").glob("*.json"))
        self.assertEqual(len(individual_paths), len(self.articles))
        individual = {
            article["id"]: article
            for article in (
                json.loads(path.read_text(encoding="utf-8")) for path in individual_paths
            )
        }
        self.assertEqual(individual, {article["id"]: article for article in self.articles})

    def test_content_is_structured_and_all_images_exist(self) -> None:
        image_count = 0
        for article in self.articles:
            self.assertTrue(any(block["type"] == "heading" for block in article["content_blocks"]))
            self.assertTrue(any(block["type"] == "paragraph" for block in article["content_blocks"]))
            images = [block for block in article["content_blocks"] if block["type"] == "image"]
            self.assertEqual(len(images), 1)
            for block in images:
                self.assertTrue((self.root / block["src"].lstrip("/")).is_file())
            image_count += len(images)
        self.assertEqual(image_count, self.manifest["article_images"])

    def test_no_denied_or_ad_interface_text_remains(self) -> None:
        serialized = json.dumps(self.articles, ensure_ascii=False).casefold()
        blocked_phrases = (
            "discovaz access denied",
            "unusual traffic",
            "research topics",
            "related searches",
            "share now",
            "functional cookies",
            "googlesyndication",
            "googleadservices",
            "adsbygoogle",
        )
        for phrase in blocked_phrases:
            self.assertNotIn(phrase, serialized)

    def test_counts_and_term_report_are_consistent(self) -> None:
        self.assertEqual(len(self.articles), self.manifest["unique_articles"])
        search_index = json.loads((self.root / "search-index.json").read_text(encoding="utf-8"))
        self.assertEqual(len(search_index), len(self.articles))
        with (self.root / "reports" / "rejected.csv").open(
            encoding="utf-8-sig", newline=""
        ) as handle:
            self.assertEqual(len(list(csv.DictReader(handle))), self.manifest["rejected_pages"])
        with (self.root / "reports" / "term-review.csv").open(
            encoding="utf-8-sig", newline=""
        ) as handle:
            term_rows = list(csv.DictReader(handle))
        self.assertEqual(len(term_rows), len(self.articles))
        self.assertTrue(all(row["validation"] == "ok" for row in term_rows))


class PowerShellEntryPointTests(unittest.TestCase):
    def test_windows_powershell_can_use_the_default_output_directory(self) -> None:
        root = Path(__file__).resolve().parent
        completed = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(root / "clean-articles.ps1"),
            ],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)


if __name__ == "__main__":
    unittest.main()
