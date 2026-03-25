import os
import time
from fastapi import FastAPI
from pydantic import BaseModel
from groq import Groq
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response
from langtrace_python_sdk import langtrace
from dotenv import load_dotenv 

load_dotenv()
# ✅ Load env variables (works in Docker if env_file is used)
LANGTRACE_API_KEY = os.getenv("LANGTRACE_API_KEY")
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
LANGTRACE_HOST = os.getenv("LANGTRACE_HOST")

# ✅ Init Langtrace BEFORE LLM
langtrace.init(
    api_key=LANGTRACE_API_KEY,
    api_host=LANGTRACE_HOST
)

# ✅ Init Groq client
client = Groq(api_key=GROQ_API_KEY)

# Prometheus metrics
REQUEST_COUNT = Counter("bot_requests_total", "Total chatbot requests")
REQUEST_LATENCY = Histogram("bot_request_latency_seconds", "Latency of chat requests")

SYSTEM_PROMPT = """
You are a Senior Cloud & DevOps Assistant.
Provide structured, production-ready answers.
"""

app = FastAPI()

class Question(BaseModel):
    message: str

@app.get("/")
def read_root():
    return {"status": "DevOps Bot is online"}

@app.post("/chat")
def chat(question: Question):
    REQUEST_COUNT.inc()
    start = time.time()

    completion = client.chat.completions.create(
        model="llama-3.1-8b-instant",
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": question.message}
        ]
    )

    REQUEST_LATENCY.observe(time.time() - start)

    return {"response": completion.choices[0].message.content}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/health")
def health():
    return {"status": "ok"}
