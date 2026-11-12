\# App



A small Python API with two endpoints: /health and /version.

This is not the point of the repo. It is the thing every other

folder packages, tests, deploys and runs. Keeping it tiny means

that when something breaks later, the app is never the suspect.



Run locally:

&#x20;   pip install -r requirements.txt

&#x20;   uvicorn main:app --reload

&#x20;   curl localhost:8000/health



Run tests:

&#x20;   pytest



\---



\# האפליקציה



API קטן ב-Python עם שני נתיבים: /health ו-/version.

זה לא העיקר בריפו. זה הדבר שכל שאר התיקיות אורזות, בודקות,

פורסות ומריצות. שמרתי אותו קטן בכוונה, כך שכשמשהו ישבר בהמשך,

האפליקציה אף פעם לא החשודה.

