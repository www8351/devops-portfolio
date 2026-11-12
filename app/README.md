# App

A small Python API with two endpoints: /health and /version.
This is not the point of the repo. It is the thing every other
folder packages, tests, deploys and runs. Keeping it tiny means
that when something breaks later, the app is never the suspect.

Run locally:

    pip install -r requirements.txt
    uvicorn main:app --reload
    curl localhost:8000/health

Run tests:

    pip install -r requirements-dev.txt
    pytest

---

# האפליקציה

`API` קטן ב-`Python` עם שני נתיבים: `/health` ו-`/version`.
זה לא העיקר בריפו. זה הדבר שכל שאר התיקיות אורזות, בודקות,
פורסות ומריצות. שמרתי אותו קטן בכוונה, כך שכשמשהו ישבר בהמשך,
האפליקציה אף פעם לא החשודה.
