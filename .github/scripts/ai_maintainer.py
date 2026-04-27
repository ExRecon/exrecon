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


def read_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


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

    with urllib.request.urlopen(req) as resp:
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


def generate_summary(context: str, is_pr: bool) -> str:
    model = os.environ.get("OPENAI_MODEL") or DEFAULT_MODEL
    guidance = (
        "You are a GitHub maintainer assistant. Produce a short Markdown summary for a repository owner. "
        "Do not provide exploit steps, payloads, or offensive tactics. Keep security advice defensive and high level."
    )
    if is_pr:
        task = (
            "Summarize this pull request for maintainers. Use these exact sections: Summary, Impact, Follow-ups. "
            "Mention risk areas and testing gaps when relevant. Keep it under 180 words."
        )
    else:
        task = (
            "Summarize this issue for maintainers. Use these exact sections: Summary, Impact, Follow-ups. "
            "Call out the likely category (bug, feature, question, docs, or maintenance) and the next best action. "
            "Keep it under 180 words."
        )

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

    with urllib.request.urlopen(req) as resp:
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


def main() -> int:
    if not os.environ.get("OPENAI_API_KEY"):
        print("OPENAI_API_KEY is not configured; skipping AI summary.")
        return 0

    repo = os.environ["GITHUB_REPOSITORY"]
    payload = read_json(os.environ["GITHUB_EVENT_PATH"])
    is_pr = "pull_request" in payload

    if is_pr:
        number = payload["pull_request"]["number"]
        context = build_pr_prompt(payload, repo)
    elif "issue" in payload:
        number = payload["issue"]["number"]
        context = build_issue_prompt(payload, repo)
    else:
        print("Unsupported event payload; nothing to do.")
        return 0

    try:
        summary = generate_summary(context, is_pr=is_pr)
        comment_body = (
            f"{COMMENT_MARKER}\n"
            "## AI Maintainer Summary\n\n"
            f"{summary}\n\n"
            f"_Generated with `{os.environ.get('OPENAI_MODEL') or DEFAULT_MODEL}` via the OpenAI Responses API._"
        )
        upsert_comment(repo, number, comment_body)
        return 0
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        print(f"HTTP error: {exc.code} {detail}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"Failed to generate summary: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
