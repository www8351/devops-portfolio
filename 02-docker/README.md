# Docker

## What this is

A container image for the app, built from a multi-stage Dockerfile, and a compose file that runs the same image with a few extra limits.

* `Dockerfile` builds the image `portfolio-app`. The first stage installs the pinned requirements into a venv. The second stage copies only that venv and `app/main.py`.
* `Dockerfile.dockerignore` keeps everything out of the build context except `app/main.py` and `app/requirements.txt`.
* `docker-compose.yml` builds and runs the image with a read only root filesystem, no Linux capabilities and no privilege escalation.

## Why it is built this way

* There are two stages. pip downloads and installs everything in the builder stage. The runtime stage gets the finished venv and the app file, nothing else. The test packages stay out, and I added no apt packages. The image has no compiler and no curl.
* The base image is `python:3.14.10-slim-trixie`, pinned by tag and by digest. The tag says which Python it is. The digest makes the build get the same bytes every time, even if the tag is pushed again. Both stages start from the same line, so the venv finds the same Python it was built with.
* The build context is the repo root, because the image needs files from `app/`. Docker reads a `.dockerignore` only from the root of the context, or with BuildKit from a file named after the Dockerfile. That is why the file is called `Dockerfile.dockerignore` and sits next to the Dockerfile. It is an allow list: ignore everything, then let two files in. The context my build sent was 448 bytes, so the local venv and the other folders never reach the builder.
* The app runs as account 10001 and group 10001, set as numbers in `USER 10001:10001`. Kubernetes can only check runAsNonRoot when the user is a number. The account has no home and no login shell. The files in the image belong to root, so the app cannot change its own code.
* The app writes nothing to disk. `PYTHONDONTWRITEBYTECODE=1` stops Python from writing .pyc files, and uvicorn writes its logs to stdout and stderr, not to files. `PYTHONUNBUFFERED=1` makes the lines show up in `docker logs` right away. That is why the compose file can set `read_only: true`.
* The health check uses Python's urllib, because the slim image has no curl and I did not want to add a package just for that. It calls /health every 10 seconds. After 3 failed checks in a row Docker marks the container unhealthy. I tested that too: with the server not started, the container turned unhealthy after about 27 seconds.
* The version comes from the build argument `APP_VERSION`, default 0.1.0. It becomes the environment variable that /version reads, and an OCI label on the image. It sits near the end of the Dockerfile, so a new version reuses every cached layer above it. A build with `APP_VERSION=abc1234` took all layers from the cache.
* uvicorn listens on 0.0.0.0 inside the container, so the published port can reach it.
* The compose file adds what this app can live with: a read only root filesystem, all capabilities dropped and `no-new-privileges`. The health check comes from the image, so compose does not repeat it.
* `docker image ls portfolio-app` shows 222MB disk usage and 53.3MB content size for `portfolio-app:0.1.0`. The base image alone shows 181MB.

## How to run

All commands run from the repo root. I ran them in PowerShell on Windows 11 with Docker Desktop.

Build the image:

```
docker build -f 02-docker/Dockerfile -t portfolio-app:0.1.0 .
```

Run it and call both endpoints:

```
docker run -d --name pf-app -p 8000:8000 portfolio-app:0.1.0
curl -s http://127.0.0.1:8000/health
curl -s http://127.0.0.1:8000/version
```

They answered `{"status":"ok"}` and `{"version":"0.1.0"}`.

Check the health status and the user:

```
docker inspect --format '{{.State.Health.Status}}' pf-app
docker exec pf-app id
```

The status was `starting` for the first seconds and `healthy` about 5 seconds after the start. `id` printed `uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)`.

Stop and remove the container:

```
docker rm -f pf-app
```

Build another version and read it back on port 8001:

```
docker build -f 02-docker/Dockerfile --build-arg APP_VERSION=abc1234 -t portfolio-app:abc1234 .
docker run -d --name pf-app-abc -p 8001:8000 portfolio-app:abc1234
curl -s http://127.0.0.1:8001/version
docker rm -f pf-app-abc
docker image rm portfolio-app:abc1234
```

/version answered `{"version":"abc1234"}`.

The compose way:

```
docker compose -f 02-docker/docker-compose.yml up -d --build
docker compose -f 02-docker/docker-compose.yml ps
curl -s http://127.0.0.1:8000/health
```

`ps` showed the service as healthy. The container runs with a read only root filesystem. This command tries to write a file in /tmp inside it:

```
docker compose -f 02-docker/docker-compose.yml exec app python -c "open('/tmp/x','w')"
```

It failed with `OSError: [Errno 30] Read-only file system: '/tmp/x'`. Stop and remove it:

```
docker compose -f 02-docker/docker-compose.yml down
```

## What I would improve

* Only fastapi and uvicorn are pinned. pip chose the versions of their dependencies during the build, so two builds can differ. A lock file with hashes would fix that.
* The digest pin never moves by itself. Security fixes in the base image only arrive when someone updates the line. I would let a bot open a pull request when a new digest comes out.
* I did not scan the image for known vulnerabilities. I would add a scanner to the build.
* The runtime image still has pip, from the base image and from the venv. The app does not need it at run time.
* The image is built for linux/amd64 only.
* Most of the 222MB is the base image. A distroless or smaller base would cut that, at the cost of a shell for debugging.

---

# דוקר

## מה זה

אימג' של קונטיינר לאפליקציה, שנבנה מ-`Dockerfile` עם שני שלבים, וקובץ `compose` שמריץ את אותו אימג' עם כמה הגבלות נוספות.

* הקובץ `Dockerfile` בונה את האימג' `portfolio-app`. השלב הראשון מתקין את החבילות הנעולות לתוך `venv`. השלב השני מעתיק רק את ה-`venv` הזה ואת `app/main.py`.
* הקובץ `Dockerfile.dockerignore` משאיר מחוץ להקשר הבנייה את כל מה שאינו `app/main.py` או `app/requirements.txt`.
* הקובץ `docker-compose.yml` בונה ומריץ את האימג' עם מערכת קבצים לקריאה בלבד, בלי `capabilities` של `Linux` ובלי הסלמת הרשאות.

## למה זה בנוי ככה

* יש שני שלבים. הכלי `pip` מוריד ומתקין הכול בשלב `builder`. שלב `runtime` מקבל את ה-`venv` המוכן ואת קובץ האפליקציה, ותו לא. חבילות הבדיקה נשארות בחוץ, ולא הוספתי חבילות `apt`. אין באימג' קומפיילר ואין `curl`.
* אימג' הבסיס הוא `python:3.14.10-slim-trixie`, נעול גם לפי תג וגם לפי `digest`. התג אומר איזו גרסת `Python` זו. ה-`digest` גורם לבנייה לקבל את אותם בתים בכל פעם, גם אם מישהו דוחף את התג מחדש. שני השלבים מתחילים מאותה שורה, כך שה-`venv` מוצא את אותו `Python` שאיתו הוא נבנה.
* הקשר הבנייה הוא שורש הריפו, כי האימג' צריך קבצים מתוך `app/`. המנוע `Docker` קורא קובץ `.dockerignore` רק משורש ההקשר, או עם `BuildKit` מקובץ שנקרא על שם ה-`Dockerfile`. לכן הקובץ נקרא `Dockerfile.dockerignore` ויושב ליד ה-`Dockerfile`. זו רשימת היתרים: מתעלמים מהכול, ואז מכניסים שני קבצים. ההקשר שהבנייה שלי שלחה היה בגודל 448 בתים, כך שה-`venv` המקומי והתיקיות האחרות לא מגיעים לבנייה.
* האפליקציה רצה תחת חשבון `10001` וקבוצה `10001`, שמוגדרים כמספרים ב-`USER 10001:10001`. מערכת `Kubernetes` יכולה לבדוק את `runAsNonRoot` רק כשהחשבון מוגדר כמספר. לחשבון אין תיקיית בית ואין מעטפת התחברות. הקבצים באימג' שייכים ל-`root`, כך שהאפליקציה לא יכולה לשנות את הקוד של עצמה.
* האפליקציה לא כותבת כלום לדיסק. המשתנה `PYTHONDONTWRITEBYTECODE=1` מונע מ-`Python` לכתוב קובצי `.pyc`, והשרת `uvicorn` כותב את הלוגים ל-`stdout` ול-`stderr`, לא לקבצים. המשתנה `PYTHONUNBUFFERED=1` גורם לשורות להופיע ב-`docker logs` מיד. לכן קובץ ה-`compose` יכול להגדיר `read_only: true`.
* בדיקת הבריאות עובדת עם `urllib` של `Python`, כי באימג' ה-`slim` אין `curl` ולא רציתי להוסיף חבילה רק בשביל זה. היא פונה אל `/health` כל 10 שניות. אחרי 3 בדיקות כושלות ברצף, המנוע `Docker` מסמן את הקונטיינר כ-`unhealthy`. בדקתי גם את זה: כשהשרת לא הופעל, הקונטיינר עבר ל-`unhealthy` אחרי כ-27 שניות.
* הגרסה מגיעה מארגומנט הבנייה `APP_VERSION`, עם ברירת המחדל `0.1.0`. הוא הופך למשתנה הסביבה ש-`/version` קורא, ולתווית `OCI` על האימג'. הוא נמצא קרוב לסוף ה-`Dockerfile`, כך שגרסה חדשה עושה שימוש חוזר בכל השכבות השמורות שמעליו. בנייה עם `APP_VERSION=abc1234` לקחה את כל השכבות מה-`cache`.
* השרת `uvicorn` מאזין על `0.0.0.0` בתוך הקונטיינר, כדי שהפורט שממופה החוצה יוכל להגיע אליו.
* קובץ ה-`compose` מוסיף את מה שהאפליקציה הזאת עומדת בו: מערכת קבצים לקריאה בלבד, הסרה של כל ה-`capabilities` ו-`no-new-privileges`. בדיקת הבריאות מגיעה מהאימג', ולכן קובץ ה-`compose` לא חוזר עליה.
* הפקודה `docker image ls portfolio-app` מציגה עבור `portfolio-app:0.1.0` שימוש בדיסק של `222MB` וגודל תוכן של `53.3MB`. אימג' הבסיס לבדו מציג `181MB`.

## איך מריצים

כל הפקודות רצות משורש הריפו. הרצתי אותן ב-`PowerShell` על `Windows 11` עם `Docker Desktop`.

בונים את האימג':

```
docker build -f 02-docker/Dockerfile -t portfolio-app:0.1.0 .
```

מריצים אותו ופונים לשני הנתיבים:

```
docker run -d --name pf-app -p 8000:8000 portfolio-app:0.1.0
curl -s http://127.0.0.1:8000/health
curl -s http://127.0.0.1:8000/version
```

התשובות היו `{"status":"ok"}` ו-`{"version":"0.1.0"}`.

בודקים את מצב הבריאות ואת החשבון:

```
docker inspect --format '{{.State.Health.Status}}' pf-app
docker exec pf-app id
```

המצב היה `starting` בשניות הראשונות ו-`healthy` כחמש שניות אחרי ההפעלה. הפקודה `id` הדפיסה `uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)`.

עוצרים ומוחקים את הקונטיינר:

```
docker rm -f pf-app
```

בונים גרסה אחרת וקוראים אותה בחזרה על פורט `8001`:

```
docker build -f 02-docker/Dockerfile --build-arg APP_VERSION=abc1234 -t portfolio-app:abc1234 .
docker run -d --name pf-app-abc -p 8001:8000 portfolio-app:abc1234
curl -s http://127.0.0.1:8001/version
docker rm -f pf-app-abc
docker image rm portfolio-app:abc1234
```

הנתיב `/version` ענה `{"version":"abc1234"}`.

הדרך עם `compose`:

```
docker compose -f 02-docker/docker-compose.yml up -d --build
docker compose -f 02-docker/docker-compose.yml ps
curl -s http://127.0.0.1:8000/health
```

הפקודה `ps` הראתה את השירות במצב `healthy`. הקונטיינר רץ עם מערכת קבצים לקריאה בלבד. הפקודה הזאת מנסה לכתוב קובץ ב-`/tmp` בתוכו:

```
docker compose -f 02-docker/docker-compose.yml exec app python -c "open('/tmp/x','w')"
```

היא נכשלה עם `OSError: [Errno 30] Read-only file system: '/tmp/x'`. עוצרים ומוחקים אותו:

```
docker compose -f 02-docker/docker-compose.yml down
```

## מה הייתי רוצה לשפר

* רק `fastapi` ו-`uvicorn` נעולים. הכלי `pip` בחר את הגרסאות של התלויות שלהם בזמן הבנייה, כך ששתי בניות יכולות להיות שונות. קובץ נעילה עם `hash` יפתור את זה.
* נעילת ה-`digest` לא זזה לבד. תיקוני אבטחה באימג' הבסיס מגיעים רק כשמישהו מעדכן את השורה. כדאי שבוט יפתח `pull request` כשיוצא `digest` חדש.
* לא סרקתי את האימג' לחולשות ידועות. כדאי להוסיף סורק לבנייה.
* באימג' של זמן הריצה עדיין יש `pip`, גם מאימג' הבסיס וגם מה-`venv`. האפליקציה לא צריכה אותו בזמן ריצה.
* האימג' נבנה רק ל-`linux/amd64`.
* רוב ה-`222MB` הם אימג' הבסיס. בסיס `distroless` או בסיס קטן יותר יקטין אותו, במחיר של ויתור על מעטפת לדיבוג.
