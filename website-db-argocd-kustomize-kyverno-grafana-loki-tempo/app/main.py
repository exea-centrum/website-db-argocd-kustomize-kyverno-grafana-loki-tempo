from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import psycopg2
import os
import logging
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI()
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

DB_CONN = os.getenv(
    "DATABASE_URL", "dbname=appdb user=appuser password=apppass host=db"
)

Instrumentator().instrument(app).expose(app)


@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    questions = ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]
    return templates.TemplateResponse(
        "form.html", {"request": request, "questions": questions}
    )


@app.post("/submit", response_class=HTMLResponse)
async def submit(request: Request, question: str = Form(...), answer: str = Form(...)):
    try:
        conn = psycopg2.connect(DB_CONN)
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS answers(
                id SERIAL PRIMARY KEY, 
                question TEXT, 
                answer TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )
        cur.execute(
            "INSERT INTO answers(question, answer) VALUES(%s, %s)", (question, answer)
        )
        conn.commit()
        logger.info(f"Zapisano odpowiedź: {question} -> {answer}")
        return templates.TemplateResponse(
            "form.html",
            {
                "request": request,
                "submitted": True,
                "questions": [
                    "Jak oceniasz usługę?",
                    "Czy polecisz nas?",
                    "Jak często korzystasz?",
                ],
            },
        )
    except Exception as e:
        logger.error(f"Błąd bazy danych: {e}")
        return templates.TemplateResponse(
            "form.html",
            {
                "request": request,
                "error": True,
                "questions": [
                    "Jak oceniasz usługę?",
                    "Czy polecisz nas?",
                    "Jak często korzystasz?",
                ],
            },
        )
    finally:
        if "cur" in locals():
            cur.close()
        if "conn" in locals():
            conn.close()


@app.get("/health")
async def health_check():
    try:
        conn = psycopg2.connect(DB_CONN)
        conn.close()
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        return {"status": "unhealthy", "database": "disconnected", "error": str(e)}


@app.get("/metrics")
async def metrics():
    return {"message": "Metrics available at /metrics endpoint"}
