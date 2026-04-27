# AI Maintainer Summary Setup

Add these files to your repository:

- `.github/workflows/ai-maintainer-summary.yml`
- `.github/scripts/ai_maintainer.py`

Then configure this repository secret:

- `OPENAI_API_KEY`

Optional repository variable:

- `OPENAI_MODEL`

If `OPENAI_MODEL` is not set, the workflow defaults to `gpt-5.4-mini`.

What it does:

- Runs on new or updated issues
- Runs on new or updated pull requests
- Calls the OpenAI Responses API
- Posts one updatable maintainer summary comment per issue or PR

The comment includes:

- `Summary`
- `Impact`
- `Follow-ups`

It also avoids giving offensive or exploit guidance and keeps security advice defensive and high-level.

Test note: this line exists only to verify the PR summary workflow path.
