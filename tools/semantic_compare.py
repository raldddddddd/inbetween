#!/usr/bin/env python3
"""Compare local NLEmbedding and MiniLM on hand and corrected-history data.

Development tooling only. Exports stay on the local machine; this script does
not upload examples. MiniLM is loaded from a local cache (and may download its
public weights when the cache is empty).
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HAND_CORPUS = ROOT / "tools" / "semantic_eval_corpus.json"
MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
MODEL_CACHE = Path(os.environ.get("INBETWEEN_MINILM_CACHE", "/private/tmp/inbetween-minilm-cache"))
PROTOTYPES = {
    "softwareDevelopment": "software development programming coding source code project workspace",
    "technicalDocumentation": "technical documentation API reference developer guide",
    "studyingLearning": "studying learning tutorial lesson educational course",
    "research": "research investigation technical analysis scholarly information",
    "workTaskExecution": "work task execution planning writing project management",
    "communication": "communication conversation messaging chat email",
    "entertainment": "entertainment funny video music celebrity movie television",
    "gaming": "video game gaming gameplay game stream",
    "generalBrowsing": "general web browsing news social media website",
}

# Evaluation-only rules. They are deliberately separate from Swift production
# thresholds; MiniLM has its own score distribution.
NATIVE_CONFIDENCE = (0.45, 0.015)
MINILM_CONFIDENCE = (0.35, 0.05)


def load_examples(paths: list[Path]) -> list[dict]:
    examples: list[dict] = []
    for path in paths:
        document = json.loads(path.read_text())
        if isinstance(document, list):
            for item in document:
                examples.append({
                    "id": item["id"], "source": "hand-authored",
                    "input": representation(item),
                    "expected": item.get("expected"), "is_ambiguous": item.get("expected") is None,
                    "manual_label": None, "correction_scope": None,
                    "automatic": None, "automatic_reasons": [], "agreement": None,
                })
        elif document.get("schemaVersion") in (1, 2) and "examples" in document:
            for item in document["examples"]:
                examples.append({
                    "id": item["id"], "source": "manual-correction",
                    "input": item["semanticInput"],
                    # Absence here is unlabeled semantic ground truth, unlike a
                    # null expected value in the hand-authored ambiguous corpus.
                    "expected": item.get("semanticCategoryLabel"), "is_ambiguous": False,
                    "manual_label": item["manualClassification"],
                    "correction_scope": item.get("correctionScope", "legacyWholeWait"),
                    "automatic": item.get("automaticClassification"),
                    "automatic_reasons": item.get("automaticReasonCodes", []),
                    "agreement": item.get("automaticAgreesWithManualCorrection"),
                })
        else:
            raise ValueError(f"Unrecognized semantic input format: {path}")
    identifiers = [f"{item['source']}:{item['id']}" for item in examples]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("Duplicate ids within one input source")
    return examples


def representation(example: dict) -> str:
    parts = [f"App: {example['app']}"]
    for key, label in [
        ("domain", "Domain"), ("pageTitle", "Page"), ("windowTitle", "Window"),
        ("resourceKind", "Resource type"), ("resourceName", "Context"),
        ("documentName", "Document"), ("resourcePath", "Path"),
    ]:
        if example.get(key):
            parts.append(f"{label}: {example[key]}")
    return " | ".join(parts)[:800]


def directory_size(path: Path) -> int:
    if not path.exists(): return 0
    seen, total = set(), 0
    for item in path.rglob("*"):
        if item.is_file():
            stat = item.stat(); identity = (stat.st_dev, stat.st_ino)
            if identity not in seen: total += stat.st_size; seen.add(identity)
    return total


def confident(result: dict, thresholds: tuple[float, float]) -> bool:
    return result["similarity"] >= thresholds[0] and result["margin"] >= thresholds[1]


def status(result: dict, example: dict, thresholds: tuple[float, float]) -> str:
    if example["source"] == "manual-correction" and example["expected"] is None:
        return "semantic label unavailable"
    is_confident = confident(result, thresholds)
    if example["is_ambiguous"]:
        return "appropriately ambiguous" if not is_confident else "confidently wrong"
    if result["category"] == example["expected"]:
        return "confidently correct" if is_confident else "uncertain correct"
    return "confidently wrong" if is_confident else "uncertain wrong"


def native_results(paths: list[Path]) -> dict[tuple[str, str], dict]:
    results = {}
    for path in paths:
        completed = subprocess.run(
            ["swift", "run", "inbetween-semantic-eval", "--json", str(path)], cwd=ROOT,
            check=True, capture_output=True, text=True,
        )
        for item in json.loads(completed.stdout):
            results[(item["source"], item["id"])] = item
    return results


def minilm_results(examples: list[dict]) -> tuple[dict[tuple[str, str], dict], dict]:
    try:
        import psutil
        from sentence_transformers import SentenceTransformer
    except ImportError as error:
        raise RuntimeError("MiniLM evaluator is unavailable; install its development environment or use --native-only") from error
    process = psutil.Process(); rss_before = process.memory_info().rss; bytes_before = directory_size(MODEL_CACHE)
    started = time.perf_counter(); model = SentenceTransformer(MODEL_NAME, cache_folder=str(MODEL_CACHE)); load_seconds = time.perf_counter() - started
    rss_after_load = process.memory_info().rss
    texts, labels = [item["input"] for item in examples], list(PROTOTYPES)
    vectors = model.encode(texts + [PROTOTYPES[label] for label in labels], normalize_embeddings=True, convert_to_numpy=True, show_progress_bar=False)
    contexts, prototypes = vectors[:len(texts)], vectors[len(texts):]
    results = {}
    for example, vector in zip(examples, contexts):
        scores = [sum(float(a) * float(b) for a, b in zip(vector, prototype)) for prototype in prototypes]
        order = sorted(range(len(scores)), key=scores.__getitem__, reverse=True); best, second = order[:2]
        results[(example["source"], example["id"])] = {
            "category": labels[best], "similarity": float(scores[best]), "runner_up": labels[second],
            "runner_up_similarity": float(scores[second]), "margin": float(scores[best] - scores[second]),
        }
    repeats = []
    for _ in range(10):
        started = time.perf_counter(); model.encode(texts, normalize_embeddings=True, convert_to_numpy=True, show_progress_bar=False)
        repeats.append((time.perf_counter() - started) / len(texts))
    return results, {"cache_bytes_before": bytes_before, "cache_bytes_after": directory_size(MODEL_CACHE), "load_seconds": load_seconds, "rss_delta": rss_after_load - rss_before, "median_repeated_seconds_per_context": statistics.median(repeats)}


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare local native semantic evaluation and MiniLM.")
    parser.add_argument("--input", action="append", type=Path, help="Hand-authored corpus or local corrected-history export; repeat for both.")
    parser.add_argument("--native-only", action="store_true", help="Do not load MiniLM.")
    args = parser.parse_args()
    paths = args.input or [HAND_CORPUS]
    examples = load_examples(paths)
    if not examples:
        print("No usable semantic contexts in the selected input."); return
    native = native_results(paths)
    minilm, metrics = ({}, None) if args.native_only else minilm_results(examples)
    print("# Semantic embedding comparison\n")
    print("| Source/context | User productivity label | Automatic result | Native top (margin) | MiniLM top (margin) | Semantic assessment |")
    print("|---|---|---|---|---|---|")
    for example in examples:
        key = (example["source"], example["id"]); native_item = native[key]
        native_result = {"category": native_item["topCategory"] or "unavailable", "similarity": native_item["topSimilarity"] or 0.0, "runner_up": native_item["competingCategory"] or "—", "runner_up_similarity": native_item["competingSimilarity"] or 0.0, "margin": native_item["margin"] or 0.0}
        native_display = f"{native_result['category']} ({native_result['similarity']:.3f}; {native_result['margin']:.3f})"
        mini_display = "not run"
        assessment = status(native_result, example, NATIVE_CONFIDENCE)
        if metrics is not None:
            mini = minilm[key]; mini_display = f"{mini['category']} ({mini['similarity']:.3f}; {mini['margin']:.3f})"
            assessment += f"; MiniLM {status(mini, example, MINILM_CONFIDENCE)}"
        automatic = example["automatic"] or "Not recorded"
        if example["agreement"] is not None: automatic += " (agrees)" if example["agreement"] else " (differs)"
        manual = example["manual_label"] or "—"
        if example.get("correction_scope"):
            manual += f" ({example['correction_scope']})"
        print(f"| {example['source']} · {example['id']} | {manual} | {automatic} | {native_display} | {mini_display} | {assessment} |")
    if metrics:
        print("\nMiniLM cost: " + f"cache/weights {metrics['cache_bytes_after']/1_000_000:.1f} MB, load {metrics['load_seconds']:.2f}s, RSS delta {metrics['rss_delta']/1_000_000:.1f} MB, repeated encode {metrics['median_repeated_seconds_per_context']*1000:.1f} ms/context.")


if __name__ == "__main__": main()
