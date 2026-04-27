#!/usr/bin/env python3
"""Generate and post AI summaries for new issues and pull requests."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

COMMENT_MARKER = "<!-- ai-maintainer-summary -->"
DEFAULT_MODEL = "gpt-5.4-mini"
MAX_BODY_CHARS = 12000
MAX_PATCH_CHARS = 12000
REQUEST_TIMEOUT_SECONDS = 45
STEP_SUMMARY_LIMIT = 1500


def read_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def log(level: str, message: str) -> None:
    print(f"[{level}] {message}")


def write_step_summary(text: str) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    with open(summary_path, "a", encoding="utf-8") as fh:
        fh.write(text.rstrip() + "\n")


def request_json(
    url: str,
    method: str = "GET",
    data: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> Any:
    payload = None if data is None else json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    if payload is not None:
        req.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        req.add_header(key, value)

    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECONDS) as resp:
        charset = resp.headers.get_content_charset() or "utf-8"
        text = resp.read().decode(charset)
        return json.loads(text) if text else None


def github_headers() -> dict[str, str]:
    token = os.environ["GITHUB_TOKEN"]
    return {
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def openai_headers() -> dict[str, str]:
    token = os.environ["OPENAI_API_KEY"]
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


def clip(text: str | None, limit: int) -> str:
    if not text:
        return ""
    if len(text) <= limit:
        return text
    return text[: limit - 15] + "\n...[truncated]"


def fetch_pr_files(repo: str, number: int) -> list[dict[str, Any]]:
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    url = f"{api_url}/repos/{repo}/pulls/{number}/files?per_page=100"
    return request_json(url, headers=github_headers())


def extract_labels(payload: dict[str, Any], is_pr: bool) -> list[str]:
    item = payload["pull_request"] if is_pr else payload["issue"]
    return [label["name"].strip().lower() for label in item.get("labels", [])]


def detect_issue_style(labels: list[str], title: str, body: str) -> tuple[str, str]:
    combined = f"{title}\n{body}".lower()
    if any(label in labels for label in ("bug", "defect", "regression")):
        return (
            "bug",
            "Treat this as a likely defect report. Focus on observed behavior, suspected scope, and debugging next steps.",
        )
    if any(label in labels for label in ("feature", "enhancement")):
        return (
            "feature",
            "Treat this as a feature request. Focus on user value, implementation surface area, and open product or design questions.",
        )
    if any(label in labels for label in ("documentation", "docs")):
        return (
            "docs",
            "Treat this as documentation work. Focus on missing clarity, affected docs surface, and the smallest useful documentation change.",
        )
    if any(label in labels for label in ("question", "support")):
        return (
            "question",
            "Treat this as a question or support request. Focus on what information is missing and the shortest path to unblock the reporter.",
        )
    if any(label in labels for label in ("maintenance", "chore")):
        return (
            "maintenance",
            "Treat this as maintenance work. Focus on operational cleanup, repo hygiene, or tooling implications.",
        )
    if "feature" in combined or "request" in combined:
        return (
            "feature",
            "Infer that this is a feature request. Focus on user value, likely implementation scope, and unresolved decisions.",
        )
    if "bug" in combined or "error" in combined or "broken" in combined:
        return (
            "bug",
            "Infer that this is a bug report. Focus on symptoms, likely impact, and debugging next steps.",
        )
    return (
        "general",
        "Treat this as a general repository issue. Focus on the clearest maintainer action and any missing details.",
    )


def detect_pr_style(labels: list[str], title: str, body: str) -> tuple[str, str]:
    combined = f"{title}\n{body}".lower()
    if any(label in labels for label in ("bug", "fix", "regression")):
        return (
            "bugfix",
            "Treat this as a bug-fix pull request. Focus on the behavior being corrected, regression risk, and validation gaps.",
        )
    if any(label in labels for label in ("feature", "enhancement")):
        return (
            "feature",
            "Treat this as a feature pull request. Focus on new capability, touched areas, rollout risk, and testing coverage.",
        )
    if any(label in labels for label in ("documentation", "docs")):
        return (
            "docs",
            "Treat this as a documentation pull request. Focus on what guidance changed and whether any docs surface may still be missing.",
        )
    if any(label in labels for label in ("maintenance", "chore", "dependencies")):
        return (
            "maintenance",
            "Treat this as maintenance work. Focus on operational impact, dependency or tooling changes, and residual upkeep tasks.",
        )
    if "readme" in combined or "docs" in combined or "documentation" in combined:
        return (
            "docs",
            "Infer this is documentation-heavy work. Focus on what guidance changed and whether the scope stays docs-only.",
        )
    return (
        "general",
        "Treat this as a general pull request. Focus on changed areas, risk, and the most important follow-up checks.",
    )


def build_issue_prompt(payload: dict[str, Any], repo: str) -> str:
    issue = payload["issue"]
    body = clip(issue.get("body", ""), MAX_BODY_CHARS)
    labels = ", ".join(label["name"] for label in issue.get("labels", [])) or "none"
    return (
        f"Repository: {repo}\n"
        f"Issue #{issue['number']}: {issue['title']}\n"
        f"Author: {issue['user']['login']}\n"
        f"Labels: {labels}\n\n"
        f"Issue body:\n{body or '[no body provided]'}\n"
    )


def build_pr_prompt(payload: dict[str, Any], repo: str) -> str:
    pr = payload["pull_request"]
    body = clip(pr.get("body", ""), MAX_BODY_CHARS)
    files = fetch_pr_files(repo, pr["number"])

    file_lines: list[str] = []
    patch_budget = MAX_PATCH_CHARS
    for file in files:
        file_lines.append(
            f"- {file['filename']} ({file['status']}, +{file.get('additions', 0)}/-{file.get('deletions', 0)})"
        )
        patch = file.get("patch")
        if patch and patch_budget > 0:
            excerpt = clip(patch, min(1200, patch_budget))
            patch_budget -= len(excerpt)
            file_lines.append(f"  Patch excerpt:\n{excerpt}")

    files_text = "\n".join(file_lines) or "[no changed files returned]"
    return (
        f"Repository: {repo}\n"
        f"Pull request #{pr['number']}: {pr['title']}\n"
        f"Author: {pr['user']['login']}\n"
        f"Base: {pr['base']['ref']}\n"
        f"Head: {pr['head']['ref']}\n\n"
        f"PR body:\n{body or '[no body provided]'}\n\n"
        f"Changed files:\n{files_text}\n"
    )


def extract_output_text(response: dict[str, Any]) -> str:
    parts: list[str] = []
    for item in response.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "output_text":
                parts.append(content.get("text", ""))
    if not parts and response.get("output_text"):
        parts.append(response["output_text"])
    return "\n".join(part.strip() for part in parts if part.strip()).strip()


def build_issue_task(payload: dict[str, Any]) -> tuple[str, str]:
    issue = payload["issue"]
    labels = extract_labels(payload, is_pr=False)
    style, guidance = detect_issue_style(labels, issue["title"], issue.get("body", ""))
    task = (
        "Summarize this issue for maintainers in concise technical Markdown. "
        "Use these exact headings: Summary, Impact, Follow-ups. "
        "Under Summary, include one bullet that starts with 'Type:'. "
        "Prefer 2-3 bullets per section, avoid filler, and keep the total under 140 words. "
        "Call out missing information only if it meaningfully blocks action. "
        f"{guidance}"
    )
    return style, task


def build_pr_task(payload: dict[str, Any]) -> tuple[str, str]:
    pr = payload["pull_request"]
    labels = extract_labels(payload, is_pr=True)
    style, guidance = detect_pr_style(labels, pr["title"], pr.get("body", ""))
    task = (
        "Summarize this pull request for maintainers in concise technical Markdown. "
        "Use these exact headings: Summary, Impact, Follow-ups. "
        "Under Summary, name the primary changed area or file group. "
        "Keep each section short, prefer direct engineering language, and keep the total under 140 words. "
        "Mention testing gaps or regression risk only when they are plausible from the diff context. "
        f"{guidance}"
    )
    return style, task


def generate_summary(context: str, task: str, style: str, is_pr: bool) -> str:
    model = os.environ.get("OPENAI_MODEL") or DEFAULT_MODEL
    guidance = (
        "You are a GitHub maintainer assistant. Produce concise technical Markdown for a repository owner. "
        "Optimize for fast triage, not general prose. "
        "Do not provide exploit steps, payloads, or offensive tactics. "
        "Keep any security advice defensive and high level."
    )
    log("INFO", f"Generating {'PR' if is_pr else 'issue'} summary with style '{style}' using model '{model}'.")

    payload = {
        "model": model,
        "max_output_tokens": 400,
        "input": [
            {
                "role": "developer",
                "content": [{"type": "input_text", "text": guidance}],
            },
            {
                "role": "user",
                "content": [{"type": "input_text", "text": f"{task}\n\n{context}"}],
            },
        ],
    }

    req = urllib.request.Request(
        "https://api.openai.com/v1/responses",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
    )
    for key, value in openai_headers().items():
        req.add_header(key, value)

    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECONDS) as resp:
        response = json.loads(resp.read().decode("utf-8"))

    text = extract_output_text(response)
    if not text:
        raise RuntimeError("OpenAI returned an empty summary")
    return text


def list_comments(repo: str, number: int) -> list[dict[str, Any]]:
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    url = f"{api_url}/repos/{repo}/issues/{number}/comments?per_page=100"
    return request_json(url, headers=github_headers())


def upsert_comment(repo: str, number: int, body: str) -> None:
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    comments = list_comments(repo, number)
    existing = next(
        (comment for comment in comments if COMMENT_MARKER in comment.get("body", "")),
        None,
    )

    if existing:
        url = f"{api_url}/repos/{repo}/issues/comments/{existing['id']}"
        request_json(url, method="PATCH", data={"body": body}, headers=github_headers())
        print(f"Updated summary comment {existing['id']}")
    else:
        url = f"{api_url}/repos/{repo}/issues/{number}/comments"
        request_json(url, method="POST", data={"body": body}, headers=github_headers())
        print(f"Created summary comment for item #{number}")


def format_failure_message(item_number: int, is_pr: bool, exc: Exception) -> str:
    item_type = "pull request" if is_pr else "issue"
    return (
        f"AI maintainer summary failed for {item_type} #{item_number}: {exc}\n"
        "Check the workflow logs for the failing API call or GitHub comment step."
    )


def main() -> int:
    if not os.environ.get("OPENAI_API_KEY"):
        log("WARNING", "OPENAI_API_KEY is not configured; skipping AI summary.")
        write_step_summary("## AI Maintainer Summary\n\nSkipped: `OPENAI_API_KEY` is not configured.")
        return 0

    repo = os.environ["GITHUB_REPOSITORY"]
    payload = read_json(os.environ["GITHUB_EVENT_PATH"])
    is_pr = "pull_request" in payload
    event_name = os.environ.get("GITHUB_EVENT_NAME", "unknown")
    log("INFO", f"Handling GitHub event '{event_name}' for repository '{repo}'.")

    if is_pr:
        pr = payload["pull_request"]
        number = pr["number"]
        log("INFO", f"Preparing PR #{number}: {pr['title']}")
        context = build_pr_prompt(payload, repo)
        style, task = build_pr_task(payload)
    elif "issue" in payload:
        issue = payload["issue"]
        number = issue["number"]
        log("INFO", f"Preparing issue #{number}: {issue['title']}")
        context = build_issue_prompt(payload, repo)
        style, task = build_issue_task(payload)
    else:
        log("WARNING", "Unsupported event payload; nothing to do.")
        write_step_summary("## AI Maintainer Summary\n\nSkipped: unsupported event payload.")
        return 0

    try:
        summary = generate_summary(context, task=task, style=style, is_pr=is_pr)
        comment_body = (
            f"{COMMENT_MARKER}\n"
            "## AI Maintainer Summary\n\n"
            f"{summary}\n\n"
            f"_Generated with `{os.environ.get('OPENAI_MODEL') or DEFAULT_MODEL}` via the OpenAI Responses API._"
        )
        upsert_comment(repo, number, comment_body)
        write_step_summary(
            "## AI Maintainer Summary\n\n"
            f"- Event: `{event_name}`\n"
            f"- Item: `#{number}`\n"
            f"- Style: `{style}`\n"
            f"- Model: `{os.environ.get('OPENAI_MODEL') or DEFAULT_MODEL}`\n\n"
            "### Generated summary preview\n\n"
            f"{clip(summary, STEP_SUMMARY_LIMIT)}"
        )
        return 0
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        error_message = f"HTTP error during AI summary generation: {exc.code} {detail}"
        print(error_message, file=sys.stderr)
        write_step_summary(
            "## AI Maintainer Summary Failure\n\n"
            f"- Event: `{event_name}`\n"
            f"- Item: `#{number}`\n"
            f"- Reason: `{clip(error_message, STEP_SUMMARY_LIMIT)}`"
        )
        return 1
    except Exception as exc:
        error_message = format_failure_message(number, is_pr, exc)
        print(error_message, file=sys.stderr)
        write_step_summary(
            "## AI Maintainer Summary Failure\n\n"
            f"- Event: `{event_name}`\n"
            f"- Item: `#{number}`\n"
            f"- Reason: `{clip(str(exc), STEP_SUMMARY_LIMIT)}`"
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
