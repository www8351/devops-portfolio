# CI/CD

## What this is

A GitHub Actions workflow that checks the app, runs its tests and builds its image on every change. On a push to `main` it also pushes the image to the GitHub Container Registry, GHCR for short.

* The workflow file is `.github/workflows/ci.yml`. GitHub reads workflows only from that folder, so `03-ci-cd` holds just this readme.
* It runs on every push to `main` and on every pull request.
* It has three jobs. `lint` runs ruff, `test` runs pytest and `build` runs `docker build`. `lint` and `test` run side by side. `build` waits for both and starts only if both passed.
* `build` builds the image from `02-docker/Dockerfile` on every run. Only on a push to `main` does it log in to GHCR and push the image as `ghcr.io/www8351/devops-portfolio:<commit sha>`. The name is the repository name in lowercase, because image names must be lowercase. On a pull request it builds the image and stops there.

## Why it is built this way

* The image tag is the full commit SHA. It points to exactly one commit, so every image can be traced back to the code it was built from. It never moves, unlike a tag such as `latest`, and two pushes never overwrite each other.
* The same SHA goes into the build argument `APP_VERSION`. The Dockerfile turns it into the environment variable that `/version` reads, so a running container reports the commit it came from. The tag and the version come from one value and cannot drift apart. I checked this locally: an image built with the current commit SHA answered with that SHA on `/version`.
* Both actions are pinned to a full 40 character commit SHA, with the release in a comment (`actions/checkout` v7.0.1, `actions/setup-python` v7.1.0). Whoever controls an action repository can move a tag like `v7` to other code. A commit SHA cannot move. The comment keeps the line readable, and an update shows up as a small diff.
* Those two are the only third party actions. Build, login and push are plain `docker` commands, not actions. That way less outside code runs next to the token.
* The workflow token can only read by default (`contents: read`). Only the `build` job asks for `packages: write`, because it is the only job that pushes. `lint` and `test` run code from the pull request, and they get no write access at all.
* The login and push steps run only when the event is a push and the ref is `refs/heads/main`. On a pull request both steps are skipped, so a pull request never pushes an image.
* The token reaches `docker login` through an environment variable and `--password-stdin`. It is never part of the command line, so it does not show up in the script or in the process list.
* Every checkout sets `persist-credentials: false`. No job pushes to git, so the token has no reason to stay in the git config, where later steps could read it.
* The `build` job sets `DOCKER_BUILDKIT: "1"`. The ignore file `02-docker/Dockerfile.dockerignore` is named after the Dockerfile, and only BuildKit reads a file with that name. Without BuildKit the whole repo would go into the build context. The variable writes that dependency down in the workflow.
* ruff is pinned to one exact version, `0.17.4`. A new ruff release can add rules or change the formatting. With the pin, the result changes only when someone changes that line. ruff is not in `requirements-dev.txt`, because the tests and the image do not need it.
* The ruff steps run from `app/`, the same folder pytest runs in. From there ruff sees `main.py` as the project's own code and accepts the import order in the tests. Run from the repo root, ruff 0.17.4 treats `main` as a third party package and asks for a different order.
* The `test` job caches pip downloads, keyed on `app/requirements-dev.txt`. When that file changes, the key changes.
* The jobs run on `ubuntu-24.04`, not `ubuntu-latest`, so the runner image does not change under the workflow when the label moves.
* Each job has a time limit in `timeout-minutes`, 10 minutes for `lint` and `test` and 15 for `build`, so a job that hangs stops long before the default limit of six hours.
* The `concurrency` setting lets only one run go at a time per branch or pull request. On a pull request a new push cancels the run still going, so no runner time goes to a commit that is already old. On `main` a run that has started is left to finish, so a newer push does not cut it off in the middle of the image push.

## How to run

All commands start from the repo root. I ran them in PowerShell on Windows 11 with Docker Desktop. I checked the workflow file with actionlint and ran the lint, test and build commands locally. The login and push steps need the token that only the workflow gets, so they are not part of the local commands.

Check the workflow file:

```
docker run --rm --name pf-ci-actionlint -v "${PWD}:/repo:ro" -w /repo rhysd/actionlint:1.7.12 -color
```

It printed nothing and exited with code 0. The image also contains shellcheck, and actionlint runs it on every `run` script in the file.

The lint job, from `app/`, in a venv with Python 3.14:

```
cd app
python -m pip install ruff==0.17.4
ruff check .
ruff format --check .
cd ..
```

ruff printed `All checks passed!` and `3 files already formatted`.

The same in a clean Linux container, closer to the runner:

```
docker run --rm --name pf-ci-lint -v "${PWD}:/repo:ro" python:3.14.10-slim-trixie sh -c "mkdir /work && cp -r --no-preserve=mode /repo/app /work/app && cd /work/app && pip install --no-cache-dir ruff==0.17.4 && ruff check . && ruff format --check ."
```

The output was the same. The repo is mounted read only and copied inside the container, so nothing is written back. `--no-preserve=mode` matters on Windows. The bind mount shows every file as executable, and ruff on Linux then reports EXE002, an executable file without a shebang, for both Python files. `git ls-files -s app` shows mode 100644 for every file, and that is what a checkout gets.

The test job:

```
python -m pip install -r app/requirements-dev.txt
cd app
pytest
cd ..
```

pytest printed `2 passed, 1 warning`. The warning is a deprecation notice from starlette about httpx.

And in a clean Linux container:

```
docker run --rm --name pf-ci-test -v "${PWD}:/repo:ro" python:3.14.10-slim-trixie sh -c "mkdir /work && cp -r --no-preserve=mode /repo/app /work/app && cd /work && python -m pip install -r app/requirements-dev.txt && cd app && pytest"
```

Same result, on Python 3.14.10.

The build job tags the image with the commit SHA and passes the same SHA as `APP_VERSION`. I did the same with the commit I had checked out:

```
git rev-parse HEAD
```

It printed `aa8ea2241272960df5d46c0ffc971db681cf8519`. Build, run and read the version back on port 8002:

```
docker build -f 02-docker/Dockerfile --build-arg "APP_VERSION=aa8ea2241272960df5d46c0ffc971db681cf8519" -t "ghcr.io/www8351/devops-portfolio:aa8ea2241272960df5d46c0ffc971db681cf8519" .
docker run -d --name pf-ci-app -p 8002:8000 ghcr.io/www8351/devops-portfolio:aa8ea2241272960df5d46c0ffc971db681cf8519
curl -s http://127.0.0.1:8002/version
docker rm -f pf-ci-app
docker image rm ghcr.io/www8351/devops-portfolio:aa8ea2241272960df5d46c0ffc971db681cf8519
```

`/version` answered `{"version":"aa8ea2241272960df5d46c0ffc971db681cf8519"}`. The tag existed only on my machine, and the last line removes it.

## What I would improve

* Run the built image inside the `build` job and call `/health` and `/version` before the push. Right now an image that builds but does not start would still be pushed.
* Scan the image for known vulnerabilities before the push, and sign it with a provenance attestation, so whoever pulls it can check where it came from.
* Keep the Docker layer cache between runs. Each run builds from scratch now and pulls the base image again.
* A waiting run on `main` can still be cancelled. GitHub keeps one running and one waiting run per group, and a newer waiting run takes the place of the older one. After three quick pushes the middle commit can end up without an image. A separate group for each commit on `main` would stop that.
* `setup-python` takes whatever 3.14 patch it finds, while the image pins 3.14.10. The tests can run on a different patch than the image.
* Run actionlint as a job in the workflow itself, so a broken workflow file shows up in the pull request.
* Let a bot open a pull request when a new action release or ruff version comes out, so the pins do not get old.

---

# צנרת `CI/CD`

## מה זה

זה `workflow` של `GitHub Actions` שבודק את האפליקציה, מריץ את הבדיקות שלה ובונה את האימג' שלה בכל שינוי. בדחיפה ל-`main` הוא גם דוחף את האימג' ל-`GitHub Container Registry`, או בקיצור `GHCR`.

* הקובץ נמצא ב-`.github/workflows/ci.yml`. המערכת `GitHub` קוראת `workflows` רק מהתיקייה הזאת, ולכן בתיקייה `03-ci-cd` יש רק את קובץ ה-`README` הזה.
* הוא רץ בכל דחיפה ל-`main` ובכל `pull request`.
* יש בו שלוש משימות. המשימה `lint` מריצה את `ruff`, המשימה `test` מריצה את `pytest` והמשימה `build` מריצה `docker build`. המשימות `lint` ו-`test` רצות במקביל. המשימה `build` מחכה לשתיהן ומתחילה רק אם שתיהן עברו.
* המשימה `build` בונה את האימג' מ-`02-docker/Dockerfile` בכל ריצה. רק בדחיפה ל-`main` היא מתחברת ל-`GHCR` ודוחפת את האימג' בשם `ghcr.io/www8351/devops-portfolio:<commit sha>`. השם הוא שם הריפו באותיות קטנות, כי שמות של אימג'ים חייבים להיות באותיות קטנות. ב-`pull request` היא בונה את האימג' ועוצרת שם.

## למה זה בנוי ככה

* תג האימג' הוא ה-`SHA` המלא של ה-`commit`. הוא מצביע על `commit` אחד בדיוק, כך שאפשר תמיד לדעת מאיזה קוד נבנה כל אימג'. הוא אף פעם לא זז, בניגוד לתג כמו `latest`, ושתי דחיפות אף פעם לא דורסות זו את זו.
* אותו `SHA` נכנס לארגומנט הבנייה `APP_VERSION`. הקובץ `Dockerfile` הופך אותו למשתנה הסביבה ש-`/version` קורא, כך שקונטיינר שרץ מדווח מאיזה `commit` הוא בא. התג והגרסה מגיעים מאותו ערך ולא יכולים להתפצל. בדקתי את זה מקומית: אימג' שנבנה עם ה-`SHA` של ה-`commit` הנוכחי ענה ב-`/version` עם אותו `SHA`.
* שתי הפעולות (`actions`) נעולות ל-`SHA` מלא של `commit`, באורך 40 תווים, עם הגרסה בהערה (`actions/checkout` בגרסה `v7.0.1`, ו-`actions/setup-python` בגרסה `v7.1.0`). מי ששולט בריפו של פעולה יכול להזיז תג כמו `v7` לקוד אחר. לעומת זאת, `SHA` של `commit` לא יכול לזוז. בזכות ההערה השורה נשארת קריאה, ועדכון נראה כשינוי קטן.
* אלה שתי הפעולות היחידות של צד שלישי. הבנייה, ההתחברות והדחיפה הן פקודות `docker` רגילות, לא פעולות. כך פחות קוד חיצוני רץ ליד ה-`token`.
* הרשאות ה-`token` של ה-`workflow` הן קריאה בלבד כברירת מחדל (`contents: read`). רק המשימה `build` מבקשת `packages: write`, כי רק היא דוחפת. המשימות `lint` ו-`test` מריצות קוד מתוך ה-`pull request`, והן לא מקבלות שום הרשאת כתיבה.
* שלבי ההתחברות והדחיפה רצים רק כשהאירוע הוא `push` וה-`ref` הוא `refs/heads/main`. ב-`pull request` מדלגים על שני השלבים, כך ש-`pull request` אף פעם לא דוחף אימג'.
* הערך של ה-`token` מגיע ל-`docker login` דרך משתנה סביבה ודרך `--password-stdin`. הוא אף פעם לא חלק משורת הפקודה, ולכן הוא לא מופיע בסקריפט ולא ברשימת התהליכים.
* כל שלב `checkout` מגדיר `persist-credentials: false`. אף משימה לא דוחפת ל-`git`, ולכן אין סיבה שה-`token` יישאר בהגדרות של `git`, שם שלבים מאוחרים יותר יכולים לקרוא אותו.
* המשימה `build` מגדירה `DOCKER_BUILDKIT: "1"`. קובץ ההתעלמות `02-docker/Dockerfile.dockerignore` נקרא על שם ה-`Dockerfile`, ורק `BuildKit` קורא קובץ בשם כזה. בלי `BuildKit` כל הריפו היה נכנס להקשר הבנייה. המשתנה רושם את התלות הזאת בתוך ה-`workflow`.
* הכלי `ruff` נעול לגרסה מדויקת אחת, `0.17.4`. גרסה חדשה של `ruff` יכולה להוסיף כללים או לשנות את העיצוב. עם הנעילה, התוצאה משתנה רק כשמישהו משנה את השורה הזאת. הכלי `ruff` לא נמצא ב-`requirements-dev.txt`, כי הבדיקות והאימג' לא צריכים אותו.
* שלבי `ruff` רצים מתוך `app/`, אותה תיקייה ש-`pytest` רץ בה. משם `ruff` רואה את `main.py` כקוד של הפרויקט עצמו ומקבל את סדר ה-`import` בבדיקות. כשמריצים אותו משורש הריפו, `ruff 0.17.4` מתייחס ל-`main` כחבילה של צד שלישי ומבקש סדר אחר.
* המשימה `test` שומרת `cache` של הורדות `pip`, עם מפתח שמחושב מ-`app/requirements-dev.txt`. כשהקובץ משתנה, המפתח משתנה.
* המשימות רצות על `ubuntu-24.04` ולא על `ubuntu-latest`, כך שאימג' ה-`runner` לא מתחלף מתחת ל-`workflow` כשהתווית זזה.
* לכל משימה יש מגבלת זמן ב-`timeout-minutes`, עשר דקות ל-`lint` ול-`test` ורבע שעה ל-`build`, כך שמשימה שנתקעת נעצרת הרבה לפני מגבלת ברירת המחדל של שש שעות.
* ההגדרה `concurrency` מאפשרת רק ריצה אחת בכל פעם לכל ענף או `pull request`. ב-`pull request` דחיפה חדשה מבטלת את הריצה שעוד רצה, כך שזמן ריצה לא הולך על `commit` שכבר ישן. ב-`main` ריצה שכבר התחילה ממשיכה עד הסוף, כך שדחיפה חדשה יותר לא קוטעת אותה באמצע הדחיפה של האימג'.

## איך מריצים

כל הפקודות מתחילות משורש הריפו. הרצתי אותן ב-`PowerShell` על `Windows 11` עם `Docker Desktop`. בדקתי את קובץ ה-`workflow` עם `actionlint`, והרצתי מקומית את הפקודות של `lint`, `test` ו-`build`. שלבי ההתחברות והדחיפה צריכים את ה-`token` שרק ה-`workflow` מקבל, ולכן הם לא חלק מהפקודות המקומיות.

בודקים את קובץ ה-`workflow`:

```
docker run --rm --name pf-ci-actionlint -v "${PWD}:/repo:ro" -w /repo rhysd/actionlint:1.7.12 -color
```

הפקודה לא הדפיסה כלום ויצאה עם קוד `0`. באימג' יש גם `shellcheck`, והכלי `actionlint` מריץ אותו על כל סקריפט `run` בקובץ.

משימת ה-`lint`, מתוך `app/`, בתוך `venv` עם `Python 3.14`:

```
cd app
python -m pip install ruff==0.17.4
ruff check .
ruff format --check .
cd ..
```

הכלי `ruff` הדפיס `All checks passed!` ו-`3 files already formatted`.

אותו דבר בקונטיינר `Linux` נקי, קרוב יותר ל-`runner`:

```
docker run --rm --name pf-ci-lint -v "${PWD}:/repo:ro" python:3.14.10-slim-trixie sh -c "mkdir /work && cp -r --no-preserve=mode /repo/app /work/app && cd /work/app && pip install --no-cache-dir ruff==0.17.4 && ruff check . && ruff format --check ."
```

הפלט היה זהה. הריפו מחובר לקריאה בלבד ומועתק בתוך הקונטיינר, כך ששום דבר לא נכתב בחזרה. הדגל `--no-preserve=mode` חשוב ב-`Windows`. ה-`bind mount` מציג כל קובץ כקובץ הרצה, ואז `ruff` ב-`Linux` מדווח `EXE002`, קובץ הרצה בלי `shebang`, על שני קובצי ה-`Python`. הפקודה `git ls-files -s app` מציגה את ההרשאות `100644` לכל קובץ, וזה מה ש-`checkout` מקבל.

משימת ה-`test`:

```
python -m pip install -r app/requirements-dev.txt
cd app
pytest
cd ..
```

הכלי `pytest` הדפיס `2 passed, 1 warning`. האזהרה היא הודעת `deprecation` של `starlette` לגבי `httpx`.

ובקונטיינר `Linux` נקי:

```
docker run --rm --name pf-ci-test -v "${PWD}:/repo:ro" python:3.14.10-slim-trixie sh -c "mkdir /work && cp -r --no-preserve=mode /repo/app /work/app && cd /work && python -m pip install -r app/requirements-dev.txt && cd app && pytest"
```

אותה תוצאה, על `Python 3.14.10`.

משימת ה-`build` מתייגת את האימג' עם ה-`SHA` של ה-`commit` ומעבירה את אותו `SHA` כ-`APP_VERSION`. עשיתי אותו דבר עם ה-`commit` שהיה אצלי:

```
git rev-parse HEAD
```

הפקודה הדפיסה `aa8ea2241272960df5d46c0ffc971db681cf8519`. בונים, מריצים וקוראים את הגרסה בחזרה על פורט `8002`:

```
docker build -f 02-docker/Dockerfile --build-arg "APP_VERSION=aa8ea2241272960df5d46c0ffc971db681cf8519" -t "ghcr.io/www8351/devops-portfolio:aa8ea2241272960df5d46c0ffc971db681cf8519" .
docker run -d --name pf-ci-app -p 8002:8000 ghcr.io/www8351/devops-portfolio:aa8ea2241272960df5d46c0ffc971db681cf8519
curl -s http://127.0.0.1:8002/version
docker rm -f pf-ci-app
docker image rm ghcr.io/www8351/devops-portfolio:aa8ea2241272960df5d46c0ffc971db681cf8519
```

הנתיב `/version` ענה `{"version":"aa8ea2241272960df5d46c0ffc971db681cf8519"}`. התג היה קיים רק במחשב שלי, והשורה האחרונה מוחקת אותו.

## מה הייתי רוצה לשפר

* כדאי להריץ את האימג' שנבנה בתוך המשימה `build` ולפנות ל-`/health` ול-`/version` לפני הדחיפה. כרגע גם אימג' שנבנה אבל לא עולה יידחף.
* כדאי לסרוק את האימג' לחולשות ידועות לפני הדחיפה, ולחתום עליו עם `attestation` של מקור, כדי שמי שמושך אותו יוכל לבדוק מאיפה הוא בא.
* כדאי לשמור את ה-`cache` של שכבות `Docker` בין ריצות. כרגע כל ריצה בונה מאפס ומושכת שוב את אימג' הבסיס.
* ריצה שמחכה בתור ב-`main` עדיין יכולה להתבטל. המערכת `GitHub` שומרת בכל קבוצה ריצה אחת שרצה וריצה אחת שמחכה, וריצה חדשה שמחכה תופסת את המקום של הריצה הישנה יותר. אחרי שלוש דחיפות מהירות ה-`commit` האמצעי יכול להישאר בלי אימג'. קבוצה נפרדת לכל `commit` ב-`main` הייתה מונעת את זה.
* הפעולה `setup-python` לוקחת את גרסת ה-`3.14` שהיא מוצאת, בזמן שהאימג' נעול ל-`3.14.10`. הבדיקות יכולות לרוץ על גרסת תיקון אחרת מזו של האימג'.
* כדאי להריץ את `actionlint` כמשימה בתוך ה-`workflow` עצמו, כך שקובץ `workflow` שבור יתגלה כבר ב-`pull request`.
* כדאי שבוט יפתח `pull request` כשיוצאת גרסה חדשה של פעולה או של `ruff`, כדי שהנעילות לא יתיישנו.
