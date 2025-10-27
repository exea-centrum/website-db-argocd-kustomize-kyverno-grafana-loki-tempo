from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import psycopg2, os, logging
from prometheus_fastapi_instrumentator import Instrumentator

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

app = FastAPI()
templates = Jinja2Templates(directory="app/templates")
DB_CONN = os.getenv("DATABASE_URL", "dbname=appdb user=appuser password=apppass host=db")

Instrumentator().instrument(app).expose(app)

QUESTIONS = [f"Pytanie {i+1}" for i in range(50)]

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("form.html", {"request": request, "questions": QUESTIONS})

@app.post("/submit", response_class=HTMLResponse)
async def submit(request: Request, **answers):
    conn = psycopg2.connect(DB_CONN)
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS answers(id SERIAL PRIMARY KEY, question TEXT, answer TEXT);")
    for question, answer in answers.items():
        cur.execute("INSERT INTO answers(question, answer) VALUES(%s, %s)", (question, answer))
        logger.info(f"Odpowiedź zapisana: {question} => {answer}")
    conn.commit()
    cur.close()
    conn.close()
    return templates.TemplateResponse("form.html", {"request": request, "submitted": True, "questions": QUESTIONS})
