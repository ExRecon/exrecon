import requests
import os

GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")
REPO = os.getenv("GITHUB_REPOSITORY")
PR_NUMBER = os.getenv("PR_NUMBER")

with open("review.txt", "r") as f:
    comment = f.read()

url = f"https://api.github.com/repos/{REPO}/issues/{PR_NUMBER}/comments"

headers = {
    "Authorization": f"token {GITHUB_TOKEN}"
}

requests.post(url, json={"body": comment}, headers=headers)