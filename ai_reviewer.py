import openai

with open("diff.txt", "r") as f:
    diff = f.read()

prompt = f"""
You are a senior cybersecurity engineer.

Review this code diff:
{diff}

Give:
- Bugs
- Security issues
- Improvements
- Optimization tips
"""

response = openai.ChatCompletion.create(
    model="gpt-5",
    messages=[{"role": "user", "content": prompt}]
)

review = response['choices'][0]['message']['content']

with open("review.txt", "w") as f:
    f.write(review)