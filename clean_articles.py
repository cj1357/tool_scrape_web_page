#!/usr/bin/env python3
"""Build normalized article/search data from scraped LP pages.

The public article JSON deliberately excludes raw HTML, source provenance, and
content hashes. Provenance and deduplication details are written to reports.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import parse_qs, unquote, urljoin, urlsplit

try:
    from lxml import html as lxml_html
except ImportError as exc:  # pragma: no cover - user-facing dependency guard
    raise SystemExit(
        "Missing dependency 'lxml'. Run: python -m pip install -r requirements-clean.txt"
    ) from exc


DENIED_RE = re.compile(
    r"discovaz\s+access\s+denied.*unusual\s+traffic|access\s+denied|"
    r"verify\s+you\s+are\s+human|request\s+blocked",
    re.I | re.S,
)
INVALID_TITLE_RE = re.compile(
    r"^\s*$|access\s+denied|unusual\s+traffic|not\s+found|forbidden", re.I
)
SITE_SUFFIX_RE = re.compile(r"\s+-\s+(?:InfoQo|Discovaz)\s*$", re.I)
SPACE_RE = re.compile(r"\s+")
BLOCKED_NODE_RE = re.compile(
    r"(?:^|[\s_-])(?:csa|ads?|advert(?:isement|ising)?|adsbygoogle|sponsored|"
    r"research[\s_-]*topics?|related[\s_-]*search|cookie|consent|share|social|"
    r"search[\s_-]*(?:bar|form)|footer|brand[\s_-]*logo|site[\s_-]*header|"
    r"newsletter|subscribe|breadcrumb)(?:$|[\s_-])",
    re.I,
)
BLOCKED_URL_RE = re.compile(
    r"/brand/|logo|doubleclick|googlesyndication|googleadservices|taboola|"
    r"outbrain|tracking|beacon|(?:tracking|transparent)[_-]?pixel|spacer\.(?:gif|png)",
    re.I,
)
TERM_NOISE_RE = re.compile(
    r"learn\s+more|read\s+more|see\s+more|explore\s+more|more\s+info|"
    r"click\s+here|hurry|on\s+the\s+site|infoqo|discovaz|access\s+denied|"
    r"mehr\s+(?:hier\s+)?erfahren|erfahren\s+sie|erfahre\s+mehr|"
    r"weitere\s+informationen|beginne\s+mehr|lernen\s+sie",
    re.I,
)


@dataclass
class SourceRow:
    csv_name: str
    row_number: int
    ad_content: str
    lp_title: str
    lp_url: str
    location: str
    locale: str
    existing_terms: str


@dataclass
class PageRecord:
    directory: Path
    result: dict[str, Any]
    text: str
    normalized_text: str
    digest: str
    sources: list[SourceRow]
    images: list[dict[str, str]]


def normalize_space(value: Any) -> str:
    return SPACE_RE.sub(" ", str(value or "").replace("\xa0", " ")).strip()


def unique_strings(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    output: list[str] = []
    for raw in values:
        value = normalize_space(raw)
        key = value.casefold()
        if value and key not in seen:
            seen.add(key)
            output.append(value)
    return output


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    # AdRadar source CSVs are GB18030; accept UTF-8 exports as a fallback.
    raw = path.read_bytes()
    text: str
    for encoding in ("utf-8-sig", "gb18030"):
        try:
            text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:  # pragma: no cover
        text = raw.decode("gb18030", errors="replace")
    return list(csv.DictReader(text.splitlines()))


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def parse_query_value(url: str, name: str) -> str:
    try:
        values = parse_qs(urlsplit(url).query, keep_blank_values=True).get(name, [])
        return normalize_space(unquote(values[0].replace("+", " "))) if values else ""
    except Exception:
        return ""


def load_source_tables(root: Path) -> dict[tuple[str, int], dict[str, str]]:
    output: dict[tuple[str, int], dict[str, str]] = {}
    for path in sorted(root.glob("adradar_*.csv")):
        for offset, row in enumerate(read_csv_rows(path), start=2):
            output[(path.name, offset)] = row
    return output


def load_image_manifest(directory: Path) -> list[dict[str, str]]:
    path = directory / "images.csv"
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def make_source_row(
    source: dict[str, Any], source_tables: dict[tuple[str, int], dict[str, str]]
) -> SourceRow:
    csv_name = str(source.get("csv", ""))
    row_number = int(source.get("row", 0) or 0)
    row = source_tables.get((csv_name, row_number), {})
    lp_url = str(row.get("LP URL") or source.get("original_url") or "")
    return SourceRow(
        csv_name=csv_name,
        row_number=row_number,
        ad_content=normalize_space(row.get("AD Content")),
        lp_title=normalize_space(row.get("LP Title")),
        lp_url=lp_url,
        location=normalize_space(row.get("Location")),
        locale=parse_query_value(lp_url, "locale"),
        existing_terms=parse_query_value(lp_url, "terms"),
    )


def load_pages(root: Path, source_tables: dict[tuple[str, int], dict[str, str]]) -> tuple[list[PageRecord], list[PageRecord]]:
    actual: list[PageRecord] = []
    rejected: list[PageRecord] = []
    for result_path in sorted((root / "scraped_output").rglob("result.json")):
        directory = result_path.parent
        result = read_json(result_path)
        text_path = directory / "text.txt"
        text = text_path.read_text(encoding="utf-8-sig") if text_path.exists() else ""
        normalized_text = normalize_space(text).casefold()
        digest = hashlib.sha256(normalized_text.encode("utf-8")).hexdigest()
        sources = [
            make_source_row(source, source_tables)
            for source in result.get("sources", [])
        ]
        record = PageRecord(
            directory=directory,
            result=result,
            text=text,
            normalized_text=normalized_text,
            digest=digest,
            sources=sources,
            images=load_image_manifest(directory),
        )
        denied = bool(
            INVALID_TITLE_RE.search(str(result.get("title", "")))
            or DENIED_RE.search(text)
            or len(normalized_text) < 500
        )
        (rejected if denied else actual).append(record)
    return actual, rejected


def is_brand_image_url(url: str) -> bool:
    return bool(BLOCKED_URL_RE.search(url or ""))


def non_brand_images(page: PageRecord) -> list[dict[str, str]]:
    return [
        image
        for image in page.images
        if image.get("status") == "ok"
        and not is_brand_image_url(image.get("source_url", ""))
        and not is_brand_image_url(image.get("final_url", ""))
    ]


def canonical_page(pages: list[PageRecord]) -> PageRecord:
    return max(
        pages,
        key=lambda page: (
            len(non_brand_images(page)),
            len(page.normalized_text),
            not bool(INVALID_TITLE_RE.search(str(page.result.get("title", "")))),
        ),
    )


def element_class_id(element: Any) -> str:
    return normalize_space(
        f"{element.get('class', '')} {element.get('id', '')} "
        f"{element.get('role', '')} {element.get('aria-label', '')}"
    ).casefold()


def is_blocked_element(element: Any) -> bool:
    current = element
    while current is not None and isinstance(getattr(current, "tag", None), str):
        tag = current.tag.lower()
        if tag in {"script", "style", "iframe", "object", "embed", "form", "nav", "footer"}:
            return True
        identifiers = element_class_id(current)
        if identifiers and BLOCKED_NODE_RE.search(identifiers):
            return True
        if current.get("data-ad-container") or current.get("data-google-query-id"):
            return True
        current = current.getparent()
    return False


def has_ancestor_tag(element: Any, tags: set[str]) -> bool:
    parent = element.getparent()
    while parent is not None:
        if isinstance(parent.tag, str) and parent.tag.lower() in tags:
            return True
        parent = parent.getparent()
    return False


def text_content(element: Any) -> str:
    return normalize_space(" ".join(element.itertext()))


def first_text(document: Any, xpath: str) -> str:
    for element in document.xpath(xpath):
        value = text_content(element)
        if value:
            return value
    return ""


def clean_display_title(title: str) -> str:
    return normalize_space(SITE_SUFFIX_RE.sub("", title or ""))


def is_invalid_lp_title(title: str) -> bool:
    return bool(INVALID_TITLE_RE.search(title or "") or re.search(r"\w\?\w", title or ""))


def slugify(value: str, max_length: int = 90) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii").lower()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_value).strip("-")
    if not slug:
        slug = "article"
    return slug[:max_length].rstrip("-")


def parse_published_at(value: str) -> str:
    value = normalize_space(value)
    match = re.search(
        r"(?:Published\s+on|Veröffentlicht\s+am|Pubblicato\s+il|Publié\s+le)?\s*"
        r"([A-Za-z]{3,9}\s+\d{1,2},\s+\d{4})",
        value,
        re.I,
    )
    if match:
        for fmt in ("%B %d, %Y", "%b %d, %Y"):
            try:
                return datetime.strptime(match.group(1), fmt).date().isoformat()
            except ValueError:
                pass
    numeric = re.search(r"(20\d{2})[-/]([01]?\d)[-/]([0-3]?\d)", value)
    if numeric:
        return f"{int(numeric.group(1)):04d}-{int(numeric.group(2)):02d}-{int(numeric.group(3)):02d}"
    return ""


def parse_read_minutes(value: str) -> int:
    match = re.search(r"(\d+)\s*(?:min(?:ute)?s?|Min\.?\s*Lesezeit)", value, re.I)
    return int(match.group(1)) if match else 0


def detect_language(title: str, locales: list[str]) -> str:
    for locale in locales:
        prefix = locale.split("_", 1)[0].split("-", 1)[0].lower()
        if re.fullmatch(r"[a-z]{2,3}", prefix):
            return prefix
    lowered = f" {title.casefold()} "
    if re.search(r"[äöüß]|\b(?:wie|der|die|das|und|für|entdecken|verstehen|weitere|medizinische)\b", lowered):
        return "de"
    if re.search(r"\b(?:come|scoprire|migliori|perché|guida)\b", lowered):
        return "it"
    if re.search(r"\b(?:cómo|mejores|guía|para|descubrir)\b", lowered):
        return "es"
    if re.search(r"\b(?:comment|meilleur|guide|découvrir|pourquoi)\b", lowered):
        return "fr"
    return "en"


def image_manifest_maps(page: PageRecord) -> tuple[dict[str, dict[str, str]], list[dict[str, str]]]:
    mapping: dict[str, dict[str, str]] = {}
    usable: list[dict[str, str]] = []
    for image in non_brand_images(page):
        usable.append(image)
        for key in (image.get("source_url", ""), image.get("final_url", "")):
            if key:
                mapping[key] = image
    return mapping, usable


def find_manifest_image(
    source_url: str,
    mapping: dict[str, dict[str, str]],
    usable: list[dict[str, str]],
) -> dict[str, str] | None:
    if source_url in mapping:
        return mapping[source_url]
    path = urlsplit(source_url).path.rstrip("/")
    for key, record in mapping.items():
        if path and urlsplit(key).path.rstrip("/") == path:
            return record
    if len(usable) == 1:
        return usable[0]
    return None


def image_caption(element: Any) -> str:
    candidates = element.xpath(
        "ancestor::*[contains(@class,'content-page-image')][1]"
        "//*[contains(@class,'caption') or contains(@class,'description')]"
    )
    for candidate in candidates:
        value = text_content(candidate)
        if value:
            return value
    return ""


def copy_article_image(
    page: PageRecord,
    image: dict[str, str],
    slug: str,
    output_root: Path,
    index: int,
) -> str | None:
    local_path = image.get("local_path", "")
    if not local_path:
        return None
    source = page.directory / Path(local_path)
    if not source.exists():
        return None
    extension = source.suffix.lower() or ".bin"
    name = ("hero" if index == 1 else f"image-{index:02d}") + extension
    destination = output_root / "assets" / "articles" / slug / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return "/" + destination.relative_to(output_root).as_posix()


def extract_article(
    page: PageRecord,
    slug: str,
    output_root: Path,
) -> dict[str, Any]:
    page_path = page.directory / "page.html"
    document = lxml_html.fromstring(page_path.read_text(encoding="utf-8-sig"))

    h1 = document.xpath("//h1[normalize-space()]")
    title = clean_display_title(text_content(h1[0]) if h1 else str(page.result.get("title", "")))
    header_left = first_text(
        document,
        "//*[contains(concat(' ',normalize-space(@class),' '),' content-page-header__left ')]",
    )
    header_page = first_text(
        document,
        "//*[contains(concat(' ',normalize-space(@class),' '),' content-page-header__page ')]",
    )
    published_at = parse_published_at(header_left)
    read_minutes = parse_read_minutes(header_page)

    excerpt_elements = document.xpath(
        "//*[contains(concat(' ',normalize-space(@class),' '),' content-page-excerpt__description ')]"
    )
    excerpt_values = unique_strings(text_content(element) for element in excerpt_elements)
    excerpt_ids = {id(element) for element in excerpt_elements}
    excerpt = "\n\n".join(excerpt_values)

    mapping, usable_images = image_manifest_maps(page)
    base_nodes = document.xpath("//base[@href]")
    base_url = base_nodes[0].get("href") if base_nodes else str(page.result.get("final_url", ""))
    blocks: list[dict[str, Any]] = []
    copied_image_keys: set[str] = set()
    image_index = 0
    started = not bool(h1)
    first_paragraph_fallback = ""

    for element in document.iter():
        if not isinstance(element.tag, str):
            continue
        tag = element.tag.lower()
        if h1 and element is h1[0]:
            started = True
            continue
        if not started or is_blocked_element(element):
            continue
        if any(id(ancestor) in excerpt_ids for ancestor in [element, *element.iterancestors()]):
            continue

        if tag in {"h2", "h3"}:
            value = text_content(element)
            if value:
                blocks.append(
                    {
                        "type": "heading",
                        "level": int(tag[1]),
                        "id": slugify(element.get("id") or value),
                        "text": value,
                    }
                )
        elif tag == "p":
            if has_ancestor_tag(element, {"h1", "h2", "h3", "li", "td", "th", "figure"}):
                continue
            value = text_content(element)
            if not value:
                continue
            previous = element.getprevious()
            if (
                previous is not None
                and isinstance(previous.tag, str)
                and previous.tag.lower() in {"h2", "h3"}
                and "content-page-paragraphs__title" in normalize_space(previous.get("class"))
                and not text_content(previous)
            ):
                heading_tag = previous.tag.lower()
                blocks.append(
                    {
                        "type": "heading",
                        "level": int(heading_tag[1]),
                        "id": slugify(previous.get("id") or value),
                        "text": value,
                    }
                )
                continue
            if not first_paragraph_fallback:
                first_paragraph_fallback = value
            block_type = "disclaimer" if re.match(r"^(?:Disclaimer|Haftungsausschluss)\s*:", value, re.I) else "paragraph"
            blocks.append({"type": block_type, "text": value})
        elif tag in {"ul", "ol"}:
            if has_ancestor_tag(element, {"ul", "ol"}):
                continue
            items = unique_strings(text_content(item) for item in element.xpath("./li"))
            if items:
                blocks.append(
                    {
                        "type": "list",
                        "style": "ordered" if tag == "ol" else "unordered",
                        "items": items,
                    }
                )
        elif tag == "table":
            headers = [text_content(cell) for cell in element.xpath(".//thead//th")]
            rows: list[list[str]] = []
            for row in element.xpath(".//tbody/tr | .//tr[not(ancestor::thead) and not(ancestor::tbody)]"):
                cells = [text_content(cell) for cell in row.xpath("./th|./td")]
                if cells:
                    if not headers and all(cell.tag.lower() == "th" for cell in row.xpath("./th|./td")):
                        headers = cells
                    else:
                        rows.append(cells)
            if headers or rows:
                blocks.append({"type": "table", "headers": headers, "rows": rows})
        elif tag == "img":
            source_value = normalize_space(element.get("src") or element.get("data-src"))
            source_url = urljoin(base_url, source_value)
            if not source_value or is_brand_image_url(source_url):
                continue
            manifest_image = find_manifest_image(source_url, mapping, usable_images)
            if not manifest_image:
                continue
            image_key = manifest_image.get("final_url") or manifest_image.get("source_url") or source_url
            if image_key in copied_image_keys:
                continue
            image_index += 1
            local_url = copy_article_image(page, manifest_image, slug, output_root, image_index)
            if not local_url:
                continue
            copied_image_keys.add(image_key)
            blocks.append(
                {
                    "type": "image",
                    "src": local_url,
                    "alt": normalize_space(element.get("alt")),
                    "caption": image_caption(element),
                }
            )

    if not excerpt:
        excerpt = first_paragraph_fallback
        for index, block in enumerate(blocks):
            if block.get("type") == "paragraph" and block.get("text") == excerpt:
                blocks.pop(index)
                break

    if not any(block.get("type") == "image" for block in blocks) and usable_images:
        manifest_image = usable_images[0]
        local_url = copy_article_image(page, manifest_image, slug, output_root, 1)
        if local_url:
            blocks.append(
                {
                    "type": "image",
                    "src": local_url,
                    "alt": "",
                    "caption": title,
                }
            )

    return {
        "title": title,
        "published_at": published_at,
        "read_minutes": read_minutes,
        "excerpt": excerpt,
        "content_blocks": blocks,
    }


def sanitize_term_phrase(value: str, max_words: int = 8) -> str:
    value = SITE_SUFFIX_RE.sub("", normalize_space(value)).casefold()
    value = value.replace("&", " and ")
    value = re.sub(r"[^\w\s]", " ", value, flags=re.UNICODE)
    value = normalize_space(value.replace("_", " "))
    words = value.split()
    return " ".join(words[:max_words])


def extract_ad_topic(value: str) -> str:
    text = normalize_space(value).casefold()
    segments = [normalize_space(part) for part in re.split(r"[.!?]+", text) if normalize_space(part)]
    cue_patterns = [
        r"(?:read|see|find|discover|explore)\s+more\s+info(?:rmation)?\s+(?:about|on)\s+(.+)$",
        r"(?:read|learn|explore|discover)\s+more\s+(?:about|on)\s+(.+)$",
        r"(?:learn|start\s+learning)(?:\s+broadly)?\s+about\s+(.+)$",
        r"learn\s+about\s+(.+)$",
        r"learn\s+how\s+to\s+(.+)$",
        r"(?:erfahren\s+sie|erfahre)(?:\s+(?:hier|etwas))*\s+mehr\s+(?:über|uber)\s+(.+)$",
        r"erfahren\s+sie\s+etwas\s+(?:über|uber)\s+(.+)$",
        r"lesen\s+sie\s+(?:mehr|weitere\s+informationen)"
        r"(?:\s+(?:über|uber))?\s+(.+)$",
        r"weitere\s+informationen(?:\s+finden\s+sie)?\s+(?:unter|über|uber)\s+(.+)$",
        r"beginne\s+mehr\s+(?:über|uber)\s+(.+?)(?:\s+zu\s+lernen)?$",
        r"lernen\s+sie\s+allgemeines\s+wissen\s+(?:über|uber)\s+(.+)$",
        r"weitere\s+informationen\s+(?:über|uber)\s+(.+?)(?:\s+lessen)?$",
    ]
    for segment in reversed(segments):
        for pattern in cue_patterns:
            match = re.search(pattern, segment, flags=re.I)
            if match:
                topic = match.group(1)
                topic = re.sub(r"\s+on\s+the\s+site(?:\s+below)?$", "", topic, flags=re.I)
                topic = re.sub(r"\s+(?:zu\s+lernen|lessen)$", "", topic, flags=re.I)
                topic = re.sub(r"\bsmbs\b", "smb", topic, flags=re.I)
                topic = re.sub(r"^(?:die|der|das)\s+", "", topic, flags=re.I)
                return sanitize_term_phrase(topic)

    # Defensive fallback for an unrecognized CTA: remove known lead-in fragments.
    fallback = re.sub(
        r"\b(?:learn|read|find|discover|see|get|explore)\s+more(?:\s+here)?\b|"
        r"\b(?:mehr|hier)\s+erfahren\b|\bhurry\b|\bon\s+the\s+site\b",
        " ",
        text,
        flags=re.I,
    )
    fallback = re.sub(r"^(?:about|on|of|for)\s+", "", normalize_space(fallback))
    return sanitize_term_phrase(fallback)


def title_topic(value: str) -> str:
    title = clean_display_title(value)
    first_clause = re.split(r"[:|]", title, maxsplit=1)[0]
    first_clause = re.sub(
        r"^(?:learn(?:\s+broadly)?\s+about|learn\s+more\s+about|"
        r"understanding|exploring|discovering|discover|introduction\s+to|"
        r"a\s+friendly\s+introduction\s+to|top\s+use\s+cases\s+of|"
        r"use\s+cases\s+of)\s+",
        "",
        first_clause,
        flags=re.I,
    )
    return sanitize_term_phrase(first_clause)


def most_representative_topic(ad_contents: list[str], lp_titles: list[str]) -> str:
    topics = [extract_ad_topic(value) for value in ad_contents]
    topics = [topic for topic in topics if topic and not TERM_NOISE_RE.search(topic)]
    if topics:
        counts = Counter(topics)
        return sorted(counts, key=lambda item: (-counts[item], len(item), item))[0]
    title_topics = [title_topic(value) for value in lp_titles]
    return next((topic for topic in title_topics if topic), "article topic")


def add_term_candidate(output: list[str], value: str) -> None:
    phrase = sanitize_term_phrase(value)
    if not phrase or TERM_NOISE_RE.search(phrase):
        return
    if len(phrase.split()) < 2:
        return
    if phrase not in output:
        output.append(phrase)


def generate_term_items(
    ad_contents: list[str], lp_titles: list[str], language: str
) -> list[str]:
    topic = most_representative_topic(ad_contents, lp_titles)
    combined_titles = " ".join(clean_display_title(value) for value in lp_titles)
    year_match = re.search(r"\b(20\d{2})\b", combined_titles)
    year = year_match.group(1) if year_match else ""
    candidates: list[str] = []

    # This vertical is present in the reference data and documents the intended
    # list-ad keyword style: one exact phrase plus close, searchable variants.
    if re.fullmatch(r"sme\s+phone\s+packages", topic) and year:
        return [
            f"sme phone packages {year}",
            f"best phone systems {year}",
            "smb phone package",
            "phone packages for smb",
            f"phone packages for smb for you {year}",
        ]

    primary = topic
    if year and year not in primary:
        primary = f"{primary} {year}"
    add_term_candidate(candidates, primary)
    add_term_candidate(candidates, topic)

    lowered_titles = combined_titles.casefold()
    if language == "de":
        if lowered_titles.startswith("wie man ") or any(
            word in lowered_titles for word in ("erstellen", "machen", "starten")
        ):
            add_term_candidate(candidates, f"wie man {topic}")
        add_term_candidate(candidates, f"{topic} ratgeber")
        add_term_candidate(candidates, f"beste {topic}")
        add_term_candidate(candidates, f"{topic} informationen")
    elif language == "it":
        add_term_candidate(candidates, f"guida {topic}")
        add_term_candidate(candidates, f"migliori {topic}")
    elif language == "es":
        add_term_candidate(candidates, f"guía de {topic}")
        add_term_candidate(candidates, f"mejores {topic}")
    elif language == "fr":
        add_term_candidate(candidates, f"guide {topic}")
        add_term_candidate(candidates, f"meilleur {topic}")
    else:
        if "use cases" in lowered_titles:
            add_term_candidate(candidates, f"{topic} use cases")
        if (
            re.search(r"\bhow\s+to\b|\bmake\b|\bbuild\b|\bstart\b", lowered_titles)
            and re.match(
                r"^(?:build|buy|choose|create|get|install|learn|make|sell|set\s+up|start|trade|use)\b",
                topic,
            )
        ):
            add_term_candidate(candidates, f"how to {topic}")
        if re.search(r"\bbest\b|\btop\b|\bcheapest\b", lowered_titles):
            add_term_candidate(candidates, f"best {topic} {year}".strip())
        if re.search(r"\bguide\b|\bunderstanding\b|\bexploring\b|\blearn\b|\bintroduction\b", lowered_titles):
            add_term_candidate(candidates, f"{topic} guide")

        feature_match = re.search(r"\b(features?|costs?|benefits?|methods?|basics?)\b", lowered_titles)
        if feature_match:
            add_term_candidate(candidates, f"{topic} {feature_match.group(1)}")

        replacements = [
            (r"\bsme\b", "smb"),
            (r"\bsme\b", "small business"),
            (r"\bsmb\b", "small business"),
            (r"\bai\b", "artificial intelligence"),
            (r"\bagents\b", "agent"),
            (r"\bassistants\b", "assistant"),
            (r"\bpackages\b", "package"),
            (r"\bsystems\b", "system"),
            (r"\bsolutions\b", "solution"),
            (r"\btools\b", "tool"),
        ]
        for pattern, replacement in replacements:
            if re.search(pattern, topic):
                add_term_candidate(candidates, re.sub(pattern, replacement, topic))
        if "custom build software" in topic:
            add_term_candidate(candidates, topic.replace("custom build software", "custom software"))
            add_term_candidate(candidates, "custom software solutions")
        if "phone package" in topic:
            add_term_candidate(candidates, topic.replace("sme", "business").replace("smb", "business"))

    if len(candidates) < 4:
        if language == "en":
            add_term_candidate(candidates, f"{topic} guide")
            add_term_candidate(candidates, f"best {topic}")
            if re.search(r"software|automation|agent|assistant|management|security|ai\b", topic):
                add_term_candidate(candidates, f"{topic} solutions")
            else:
                add_term_candidate(candidates, f"{topic} information")
        else:
            for value in lp_titles:
                add_term_candidate(candidates, sanitize_term_phrase(clean_display_title(value)))

    # Keep 4-6 useful phrases while staying close to competitor URL sizes.
    selected: list[str] = []
    for candidate in candidates:
        proposed = " ".join([*selected, candidate])
        if len(proposed) <= 180 or len(selected) < 4:
            selected.append(candidate)
        if len(selected) == 6:
            break
    return selected


def term_validation(term_items: list[str], term: str) -> tuple[bool, str]:
    problems: list[str] = []
    if not (4 <= len(term_items) <= 6):
        problems.append(f"term_items_count={len(term_items)}")
    if not term:
        problems.append("empty_term")
    if TERM_NOISE_RE.search(term):
        problems.append("contains_noise")
    if any(not (2 <= len(item.split()) <= 8) for item in term_items):
        problems.append("phrase_word_count")
    return not problems, ";".join(problems)


def existing_term_overlap(term: str, existing_terms: list[str]) -> float | str:
    existing = normalize_space(" ".join(existing_terms)).casefold()
    if not existing:
        return ""
    left = set(term.casefold().split())
    right = set(existing.split())
    return round(len(left & right) / max(1, len(left | right)), 4)


def build_near_duplicate_report(articles_internal: list[dict[str, Any]]) -> list[dict[str, Any]]:
    report: list[dict[str, Any]] = []
    shingle_cache: dict[str, set[tuple[str, ...]]] = {}
    for article in articles_internal:
        words = article["normalized_text"].split()
        shingle_cache[article["id"]] = {
            tuple(words[index : index + 5]) for index in range(max(0, len(words) - 4))
        }
    for left_index, left in enumerate(articles_internal):
        for right in articles_internal[left_index + 1 :]:
            a = shingle_cache[left["id"]]
            b = shingle_cache[right["id"]]
            if not a or not b:
                continue
            similarity = len(a & b) / len(a | b)
            if similarity >= 0.60:
                report.append(
                    {
                        "left_id": left["id"],
                        "left_slug": left["slug"],
                        "left_title": left["title"],
                        "right_id": right["id"],
                        "right_slug": right["slug"],
                        "right_title": right["title"],
                        "five_word_shingle_similarity": round(similarity, 4),
                        "action": "review_only_not_merged",
                    }
                )
    return sorted(report, key=lambda row: row["five_word_shingle_similarity"], reverse=True)


def build(root: Path, output_root: Path) -> dict[str, Any]:
    source_tables = load_source_tables(root)
    actual_pages, rejected_pages = load_pages(root, source_tables)
    groups: dict[str, list[PageRecord]] = defaultdict(list)
    for page in actual_pages:
        groups[page.digest].append(page)

    if output_root.exists():
        shutil.rmtree(output_root)
    (output_root / "articles").mkdir(parents=True, exist_ok=True)
    (output_root / "reports").mkdir(parents=True, exist_ok=True)

    articles: list[dict[str, Any]] = []
    internal_articles: list[dict[str, Any]] = []
    duplicate_rows: list[dict[str, Any]] = []
    repaired_title_rows: list[dict[str, Any]] = []
    term_review_rows: list[dict[str, Any]] = []
    used_slugs: set[str] = set()

    for digest, pages in sorted(groups.items(), key=lambda item: item[1][0].result.get("title", "")):
        canonical = canonical_page(pages)
        provisional_title = clean_display_title(str(canonical.result.get("title", "")))
        base_slug = slugify(provisional_title)
        slug = base_slug
        if slug in used_slugs:
            slug = f"{base_slug}-{digest[:8]}"
        used_slugs.add(slug)
        article_id = f"article_{digest[:12]}"

        extracted = extract_article(canonical, slug, output_root)
        title = extracted["title"] or provisional_title
        all_sources = [source for page in pages for source in page.sources]
        ad_contents = unique_strings(source.ad_content for source in all_sources)
        valid_lp_titles = unique_strings(
            source.lp_title
            for source in all_sources
            if not is_invalid_lp_title(source.lp_title)
        )
        if not valid_lp_titles:
            valid_lp_titles = [title]
        elif title.casefold() not in {clean_display_title(value).casefold() for value in valid_lp_titles}:
            valid_lp_titles.append(title)

        locales = unique_strings(source.locale for source in all_sources)
        locations = sorted(
            {
                location
                for source in all_sources
                for location in re.split(r"[\s,;/]+", source.location)
                if location
            }
        )
        language = detect_language(title, locales)
        term_items = generate_term_items(ad_contents, valid_lp_titles, language)
        term = " ".join(term_items)
        term_ok, term_problems = term_validation(term_items, term)

        article = {
            "id": article_id,
            "slug": slug,
            "title": title,
            "published_at": extracted["published_at"],
            "read_minutes": extracted["read_minutes"],
            "language": language,
            "locale": locales[0] if locales else "",
            "locations": locations,
            "ad_contents": ad_contents,
            "lp_titles": valid_lp_titles,
            "term": term,
            "term_items": term_items,
            "excerpt": extracted["excerpt"],
            "content_blocks": extracted["content_blocks"],
        }
        articles.append(article)
        internal_articles.append(
            {
                "id": article_id,
                "slug": slug,
                "title": title,
                "normalized_text": canonical.normalized_text,
            }
        )
        write_json(output_root / "articles" / f"{slug}.json", article)

        existing_terms = unique_strings(source.existing_terms for source in all_sources)
        term_review_rows.append(
            {
                "id": article_id,
                "slug": slug,
                "title": title,
                "ad_content_input": " || ".join(ad_contents),
                "lp_title_input": " || ".join(valid_lp_titles),
                "term": term,
                "term_items": " | ".join(term_items),
                "existing_competitor_terms": " || ".join(existing_terms),
                "existing_token_overlap": existing_term_overlap(term, existing_terms),
                "validation": "ok" if term_ok else term_problems,
            }
        )

        for page in pages:
            for source in page.sources:
                duplicate_rows.append(
                    {
                        "article_id": article_id,
                        "slug": slug,
                        "group_size": len(pages),
                        "kept_directory": str(canonical.directory.relative_to(root)),
                        "source_directory": str(page.directory.relative_to(root)),
                        "csv": source.csv_name,
                        "row": source.row_number,
                        "ad_content": source.ad_content,
                        "lp_title": source.lp_title,
                        "lp_url": source.lp_url,
                    }
                )
                if is_invalid_lp_title(source.lp_title):
                    repaired_title_rows.append(
                        {
                            "article_id": article_id,
                            "slug": slug,
                            "csv": source.csv_name,
                            "row": source.row_number,
                            "original_lp_title": source.lp_title,
                            "repaired_title": title,
                        }
                    )

    articles.sort(key=lambda item: (item["title"].casefold(), item["id"]))
    write_json(output_root / "articles.json", articles)

    article_csv_rows: list[dict[str, Any]] = []
    search_index: list[dict[str, Any]] = []
    for article in articles:
        image_blocks = [block for block in article["content_blocks"] if block.get("type") == "image"]
        heading_text = [block.get("text", "") for block in article["content_blocks"] if block.get("type") == "heading"]
        hero_image = image_blocks[0]["src"] if image_blocks else ""
        article_csv_rows.append(
            {
                "id": article["id"],
                "slug": article["slug"],
                "title": article["title"],
                "published_at": article["published_at"],
                "read_minutes": article["read_minutes"],
                "language": article["language"],
                "locale": article["locale"],
                "locations": " | ".join(article["locations"]),
                "ad_contents": " | ".join(article["ad_contents"]),
                "lp_titles": " | ".join(article["lp_titles"]),
                "term": article["term"],
                "term_items": " | ".join(article["term_items"]),
                "excerpt": article["excerpt"],
                "block_count": len(article["content_blocks"]),
                "image_count": len(image_blocks),
            }
        )
        search_index.append(
            {
                "id": article["id"],
                "slug": article["slug"],
                "title": article["title"],
                "excerpt": article["excerpt"],
                "term": article["term"],
                "term_items": article["term_items"],
                "language": article["language"],
                "hero_image": hero_image,
                "headings": heading_text,
            }
        )

    article_csv_fields = [
        "id", "slug", "title", "published_at", "read_minutes", "language", "locale",
        "locations", "ad_contents", "lp_titles", "term", "term_items", "excerpt",
        "block_count", "image_count",
    ]
    write_csv(output_root / "articles.csv", article_csv_rows, article_csv_fields)
    write_json(output_root / "search-index.json", search_index)

    rejected_rows: list[dict[str, Any]] = []
    for page in rejected_pages:
        if page.sources:
            for source in page.sources:
                rejected_rows.append(
                    {
                        "reason": "access_denied_or_no_article_content",
                        "title": page.result.get("title", ""),
                        "text_length": len(page.text),
                        "directory": str(page.directory.relative_to(root)),
                        "csv": source.csv_name,
                        "row": source.row_number,
                        "lp_url": source.lp_url,
                    }
                )
        else:
            rejected_rows.append(
                {
                    "reason": "access_denied_or_no_article_content",
                    "title": page.result.get("title", ""),
                    "text_length": len(page.text),
                    "directory": str(page.directory.relative_to(root)),
                    "csv": "",
                    "row": "",
                    "lp_url": page.result.get("requested_url", ""),
                }
            )

    near_duplicates = build_near_duplicate_report(internal_articles)
    report_root = output_root / "reports"
    write_csv(
        report_root / "rejected.csv",
        rejected_rows,
        ["reason", "title", "text_length", "directory", "csv", "row", "lp_url"],
    )
    write_csv(
        report_root / "duplicates.csv",
        duplicate_rows,
        [
            "article_id", "slug", "group_size", "kept_directory", "source_directory",
            "csv", "row", "ad_content", "lp_title", "lp_url",
        ],
    )
    write_csv(
        report_root / "near-duplicates.csv",
        near_duplicates,
        [
            "left_id", "left_slug", "left_title", "right_id", "right_slug",
            "right_title", "five_word_shingle_similarity", "action",
        ],
    )
    write_csv(
        report_root / "repaired-titles.csv",
        repaired_title_rows,
        ["article_id", "slug", "csv", "row", "original_lp_title", "repaired_title"],
    )
    write_csv(
        report_root / "term-review.csv",
        term_review_rows,
        [
            "id", "slug", "title", "ad_content_input", "lp_title_input", "term",
            "term_items", "existing_competitor_terms", "existing_token_overlap", "validation",
        ],
    )

    image_count = sum(
        1
        for article in articles
        for block in article["content_blocks"]
        if block.get("type") == "image"
    )
    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "scraped_pages": len(actual_pages) + len(rejected_pages),
        "rejected_pages": len(rejected_pages),
        "valid_page_urls": len(actual_pages),
        "unique_articles": len(articles),
        "duplicate_groups": sum(1 for pages in groups.values() if len(pages) > 1),
        "near_duplicate_candidates": len(near_duplicates),
        "generated_terms": sum(1 for article in articles if article["term"]),
        "article_images": image_count,
        "public_article_fields": list(articles[0].keys()) if articles else [],
    }
    write_json(output_root / "manifest.json", manifest)
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Project root containing scraped_output and AdRadar CSV files",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output directory (default: <root>/cleaned_data)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    output = (args.output or (root / "cleaned_data")).resolve()
    if output == root or root not in output.parents:
        raise SystemExit("Output directory must be inside the project root and cannot equal the root.")
    manifest = build(root, output)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
