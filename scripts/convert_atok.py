#!/usr/bin/env python3
"""Convert ATOK dictionary export to azooKey format."""

import json
import re
import sys
from pathlib import Path


def is_hiragana(text: str) -> bool:
    """Check if text contains only hiragana (and allowed characters)."""
    # Allow hiragana, prolonged sound mark, and some punctuation
    pattern = r'^[\u3040-\u309F\u30FC\u30A0ー]+$'
    return bool(re.match(pattern, text))


def normalize_reading(reading: str) -> str:
    """Normalize reading to hiragana."""
    # Convert fullwidth numbers to halfwidth
    reading = reading.translate(str.maketrans('１２３４５６７８９０', '1234567890'))
    # Convert fullwidth alphabet to halfwidth
    reading = reading.translate(str.maketrans(
        'ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ',
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    ))
    return reading


def convert_atok_to_azookey(atok_path: str, output_path: str = None,
                            skip_emoticons: bool = True,
                            skip_auto: bool = False):
    """Convert ATOK dictionary to azooKey format."""

    entries = []
    seen = set()  # Track unique (word, reading) pairs
    skipped_emoticons = 0
    skipped_auto = 0
    skipped_invalid = 0
    skipped_duplicates = 0

    # Read ATOK file (UTF-16LE with BOM)
    with open(atok_path, 'r', encoding='utf-16-le') as f:
        for line in f:
            line = line.strip()

            # Skip header lines
            if line.startswith('!!') or not line:
                continue

            # Parse tab-separated fields
            parts = line.split('\t')
            if len(parts) < 3:
                continue

            reading = parts[0].strip()
            word = parts[1].strip()
            word_type = parts[2].strip()

            # Skip emoticons
            if skip_emoticons and ('顔文字' in word_type or '単漢字' in word_type or '短縮読み' in word_type):
                if reading.startswith('＠') or reading.startswith('@'):
                    skipped_emoticons += 1
                    continue

            # Skip auto-registered words (ends with $)
            if skip_auto and word_type.endswith('$'):
                skipped_auto += 1
                continue

            # Normalize reading
            reading = normalize_reading(reading)

            # Skip if reading is not valid hiragana
            if not is_hiragana(reading):
                skipped_invalid += 1
                continue

            # Skip duplicates
            key = (word, reading)
            if key in seen:
                skipped_duplicates += 1
                continue
            seen.add(key)

            entries.append({
                'word': word,
                'reading': reading
            })

    print(f"Converted: {len(entries)} entries")
    print(f"Skipped emoticons: {skipped_emoticons}")
    print(f"Skipped auto-registered: {skipped_auto}")
    print(f"Skipped invalid reading: {skipped_invalid}")
    print(f"Skipped duplicates: {skipped_duplicates}")

    # Output
    if output_path:
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump({'entries': entries}, f, ensure_ascii=False, indent=2)
        print(f"Saved to: {output_path}")

    return entries


def merge_with_existing(new_entries: list, settings_path: str):
    """Merge new entries with existing settings.json."""

    # Load existing settings
    settings = {}
    if Path(settings_path).exists():
        with open(settings_path, 'r', encoding='utf-8') as f:
            settings = json.load(f)

    # Get existing dictionary entries
    existing = settings.get('dictionary', {}).get('entries', [])
    existing_keys = {(e['word'], e['reading']) for e in existing}

    # Add new entries that don't exist
    added = 0
    for entry in new_entries:
        key = (entry['word'], entry['reading'])
        if key not in existing_keys:
            existing.append(entry)
            existing_keys.add(key)
            added += 1

    # Update settings
    if 'dictionary' not in settings:
        settings['dictionary'] = {}
    settings['dictionary']['entries'] = existing

    # Save
    with open(settings_path, 'w', encoding='utf-8') as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)

    print(f"Added {added} new entries to {settings_path}")
    print(f"Total entries: {len(existing)}")


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='Convert ATOK dictionary to azooKey format')
    parser.add_argument('atok_file', help='Path to ATOK export file')
    parser.add_argument('--output', '-o', help='Output JSON file path')
    parser.add_argument('--merge', '-m', help='Merge with existing settings.json')
    parser.add_argument('--skip-emoticons', action='store_true', default=True,
                        help='Skip emoticon entries (default: True)')
    parser.add_argument('--skip-auto', action='store_true', default=False,
                        help='Skip auto-registered words (default: False)')

    args = parser.parse_args()

    entries = convert_atok_to_azookey(
        args.atok_file,
        args.output,
        skip_emoticons=args.skip_emoticons,
        skip_auto=args.skip_auto
    )

    if args.merge:
        merge_with_existing(entries, args.merge)
