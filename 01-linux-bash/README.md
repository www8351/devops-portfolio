# Linux and Bash

## What this is

Three Bash scripts that run and watch the app on a plain Linux host, without containers. A fourth script tests them.

* `setup.sh` installs the app on Ubuntu or Debian. It creates a service account, copies the app to /opt/portfolio-app, builds a venv, installs the pinned requirements, creates the log folder and writes a systemd unit file.
* `healthcheck.sh` calls /health once and appends one line to a log. It prints nothing when the app is healthy, so it fits in cron.
* `log-report.sh` reads that log and prints the total checks, the failures and the time of the last failure.
* `verify.sh` is the test for this folder. It runs the other three inside an Ubuntu 24.04 container.

## Why it is built this way

* The app runs as `appuser`, a system account with no login shell and no home dir. The code in /opt/portfolio-app belongs to root, so the app cannot change its own code. The account owns only the log folder.
* The venv lives inside the install dir, so the app's packages stay away from the system Python.
* The unit file tells systemd to start the app at boot and to restart it if it crashes. I added a little hardening: NoNewPrivileges, PrivateTmp, ProtectHome and ProtectSystem=full. I stopped there, because systemd never ran this unit and stricter settings need a real host to test.
* The unit file starts uvicorn with `--host 0.0.0.0`. The app listens on all network interfaces on the chosen port, so other machines can reach it. A firewall or a cloud security group decides who gets in.
* `setup.sh` is safe to run twice. It skips the account and the venv when they already exist and writes the files again.
* `healthcheck.sh` is made for cron. It is silent when the app is healthy and prints one line on stderr when it is not, so cron only reports real problems. The exit code says what happened: 0 healthy, 1 not healthy or log not writable, 2 bad option. A failed curl call does not stop the script before the FAIL line is written.
* The log is plain text, one line per check. grep and awk are enough to read it, and `log-report.sh` is a few lines of awk.
* All four scripts run with `set -euo pipefail`, print a usage message with -h, and exit with 2 on a bad option.
* I tested in a throwaway container, so every run started from a clean Ubuntu.

## How to run

All four scripts ran in an Ubuntu 24.04 container, from the repo root, with this command:

```
docker run --rm --name pf-linux-bash -v "${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash 01-linux-bash/verify.sh
```

`verify.sh` installs python3, python3-venv and curl, runs `setup.sh` twice, starts the app as appuser and checks that it does not run as root. Then it runs `healthcheck.sh` with the app up and again with the app stopped, and checks the log and the report line by line. It also checks that `setup.sh` refuses a bad user name and a relative install dir. The repo is mounted read only. The end of the output from my run:

```
Log (/var/log/portfolio-app/health.log):
2026-11-12T04:41:50Z OK http=200 url=http://127.0.0.1:8000/health
2026-11-12T04:41:51Z FAIL http=000 url=http://127.0.0.1:8000/health reason="could not connect"

Report:
Log file:          /var/log/portfolio-app/health.log
Total checks:      2
Failures:          1
Last failure time: 2026-11-12T04:41:51Z

VERIFY PASSED
```

The container has no systemd. `setup.sh` wrote the unit file there but did not start the service, and `verify.sh` started the app by hand as appuser instead. So systemd never ran the unit. I only checked the file. This command installs systemd in a fresh container, runs `setup.sh` and then runs `systemd-analyze verify` on the unit file:

```
docker run --rm --name pf-linux-bash-unit -e DEBIAN_FRONTEND=noninteractive -v "${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 python3-venv systemd >/dev/null && bash 01-linux-bash/setup.sh >/dev/null && systemd-analyze verify /etc/systemd/system/portfolio-app.service && echo unit file verified"
```

It printed one debconf notice from apt and then `unit file verified`. The exit code was 0.

I did not run the next commands on a real Ubuntu host. They use the same scripts and defaults that ran in the container. From the repo root:

```
sudo ./01-linux-bash/setup.sh
sudo install -m 0755 01-linux-bash/healthcheck.sh 01-linux-bash/log-report.sh /usr/local/bin/
sudo -u appuser /usr/local/bin/healthcheck.sh
/usr/local/bin/log-report.sh
```

The health check runs as appuser because that account owns the log folder. A sample cron line for /etc/cron.d/portfolio-app, one check every five minutes:

```
*/5 * * * * appuser /usr/local/bin/healthcheck.sh
```

Each script prints its options with -h.

## What I would improve

* On a second run `setup.sh` copies the new code but does not restart a service that is already running. Today that needs `sudo systemctl restart portfolio-app`. I would restart it when the files change.
* The venv is built from the host's python3. On Ubuntu 24.04 that is Python 3.12, while the rest of the repo uses 3.14. I would pin the Python version on the host too.
* Only fastapi and uvicorn are pinned. Their dependencies are not, so two installs can differ. A lock file would fix that.
* The health log grows forever. A logrotate rule would keep it small.
* I would run the unit on a real VM with systemd, not only check the file.

---

# לינוקס ו-`Bash`

## מה זה

שלושה סקריפטים של `Bash` שמריצים את האפליקציה ומשגיחים עליה על שרת `Linux` רגיל, בלי קונטיינרים. סקריפט רביעי בודק אותם.

* הסקריפט `setup.sh` מתקין את האפליקציה על `Ubuntu` או `Debian`. הוא יוצר חשבון שירות, מעתיק את האפליקציה אל `/opt/portfolio-app`, בונה `venv`, מתקין את החבילות הנעולות, יוצר את תיקיית הלוגים וכותב קובץ `unit` של `systemd`.
* הסקריפט `healthcheck.sh` פונה אל `/health` פעם אחת ומוסיף שורה אחת ללוג. כשהאפליקציה תקינה הוא לא מדפיס כלום, ולכן הוא מתאים ל-`cron`.
* הסקריפט `log-report.sh` קורא את הלוג ומדפיס את מספר הבדיקות, את מספר הכישלונות ואת זמן הכישלון האחרון.
* הסקריפט `verify.sh` הוא הבדיקה של התיקייה הזאת. הוא מריץ את שלושת האחרים בתוך קונטיינר `Ubuntu 24.04`.

## למה זה בנוי ככה

* האפליקציה רצה תחת `appuser`, חשבון מערכת בלי מעטפת התחברות ובלי תיקיית בית. הקוד ב-`/opt/portfolio-app` שייך ל-`root`, כך שהאפליקציה לא יכולה לשנות את הקוד של עצמה. לחשבון שייכת רק תיקיית הלוגים.
* סביבת ה-`venv` נמצאת בתוך תיקיית ההתקנה, כך שהחבילות של האפליקציה לא מתערבבות עם ה-`Python` של המערכת.
* קובץ ה-`unit` אומר ל-`systemd` להפעיל את האפליקציה בעליית המערכת ולהפעיל אותה מחדש אם היא קורסת. הוספתי מעט הקשחה: `NoNewPrivileges`, `PrivateTmp`, `ProtectHome` ו-`ProtectSystem=full`. לא הוספתי יותר, כי `systemd` אף פעם לא הריץ את קובץ ה-`unit` הזה, ואת ההגדרות המחמירות יותר צריך לבדוק על שרת אמיתי.
* קובץ ה-`unit` מפעיל את `uvicorn` עם `--host 0.0.0.0`. האפליקציה מאזינה בכל ממשקי הרשת על הפורט שנבחר, כך שמחשבים אחרים יכולים להגיע אליה. חומת אש או `security group` בענן קובעים מי נכנס.
* בטוח להריץ את `setup.sh` פעמיים. הוא מדלג על החשבון ועל ה-`venv` כשהם כבר קיימים, וכותב את הקבצים מחדש.
* הסקריפט `healthcheck.sh` נבנה בשביל `cron`. הוא שקט כשהאפליקציה תקינה ומדפיס שורה אחת ל-`stderr` כשהיא לא, כך ש-`cron` מדווח רק על בעיות אמיתיות. קוד היציאה מספר מה קרה: `0` תקין, `1` לא תקין או שאי אפשר לכתוב ללוג, `2` אפשרות שגויה. קריאת `curl` שנכשלה לא עוצרת את הסקריפט לפני ששורת ה-`FAIL` נכתבת.
* הלוג הוא טקסט פשוט, שורה אחת לכל בדיקה. מספיקים `grep` ו-`awk` כדי לקרוא אותו, והסקריפט `log-report.sh` הוא כמה שורות של `awk`.
* כל ארבעת הסקריפטים רצים עם `set -euo pipefail`, מדפיסים הודעת שימוש עם `-h`, ויוצאים עם `2` על אפשרות שגויה.
* בדקתי בקונטיינר שזורקים אחרי כל ריצה, כך שכל ריצה התחילה מ-`Ubuntu` נקי.

## איך מריצים

כל ארבעת הסקריפטים רצו בקונטיינר `Ubuntu 24.04`, מתיקיית השורש של הריפו, עם הפקודה הזאת:

```
docker run --rm --name pf-linux-bash -v "${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash 01-linux-bash/verify.sh
```

הסקריפט `verify.sh` מתקין את `python3`, `python3-venv` ו-`curl`, מריץ את `setup.sh` פעמיים, מפעיל את האפליקציה תחת `appuser` ובודק שהיא לא רצה כ-`root`. אחר כך הוא מריץ את `healthcheck.sh` כשהאפליקציה פועלת ושוב כשהיא עצורה, ובודק את הלוג ואת הדוח שורה אחר שורה. הוא גם בודק שהסקריפט `setup.sh` דוחה שם חשבון לא תקין ותיקיית התקנה עם נתיב יחסי. הריפו מחובר לקריאה בלבד. סוף הפלט מהריצה שלי:

```
Log (/var/log/portfolio-app/health.log):
2026-11-12T04:41:50Z OK http=200 url=http://127.0.0.1:8000/health
2026-11-12T04:41:51Z FAIL http=000 url=http://127.0.0.1:8000/health reason="could not connect"

Report:
Log file:          /var/log/portfolio-app/health.log
Total checks:      2
Failures:          1
Last failure time: 2026-11-12T04:41:51Z

VERIFY PASSED
```

אין `systemd` בתוך הקונטיינר. הסקריפט `setup.sh` כתב שם את קובץ ה-`unit` אבל לא הפעיל את השירות, והסקריפט `verify.sh` הפעיל את האפליקציה ידנית תחת `appuser` במקום זה. כלומר `systemd` אף פעם לא הריץ את קובץ ה-`unit`. בדקתי רק את הקובץ. הפקודה הזאת מתקינה `systemd` בקונטיינר חדש, מריצה את `setup.sh` ואז מריצה את `systemd-analyze verify` על קובץ ה-`unit`:

```
docker run --rm --name pf-linux-bash-unit -e DEBIAN_FRONTEND=noninteractive -v "${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 python3-venv systemd >/dev/null && bash 01-linux-bash/setup.sh >/dev/null && systemd-analyze verify /etc/systemd/system/portfolio-app.service && echo unit file verified"
```

הפקודה הדפיסה הודעה אחת של `debconf` מ-`apt` ואחריה את `unit file verified`. קוד היציאה היה `0`.

לא הרצתי את הפקודות הבאות על שרת `Ubuntu` אמיתי. אלה אותם סקריפטים ואותן ברירות מחדל שרצו בקונטיינר. מתיקיית השורש של הריפו:

```
sudo ./01-linux-bash/setup.sh
sudo install -m 0755 01-linux-bash/healthcheck.sh 01-linux-bash/log-report.sh /usr/local/bin/
sudo -u appuser /usr/local/bin/healthcheck.sh
/usr/local/bin/log-report.sh
```

הבדיקה רצה תחת `appuser` כי החשבון הזה הוא הבעלים של תיקיית הלוגים. שורת `cron` לדוגמה עבור `/etc/cron.d/portfolio-app`, בדיקה אחת כל חמש דקות:

```
*/5 * * * * appuser /usr/local/bin/healthcheck.sh
```

כל סקריפט מדפיס את האפשרויות שלו עם `-h`.

## מה הייתי רוצה לשפר

* בהרצה שנייה הסקריפט `setup.sh` מעתיק את הקוד החדש אבל לא מפעיל מחדש שירות שכבר רץ. היום צריך בשביל זה `sudo systemctl restart portfolio-app`. כדאי להפעיל אותו מחדש כשהקבצים משתנים.
* סביבת ה-`venv` נבנית מה-`python3` של השרת. ב-`Ubuntu 24.04` זו גרסה `3.12`, ושאר הריפו עובד עם `3.14`. כדאי לנעול גם את גרסת ה-`Python` על השרת.
* רק `fastapi` ו-`uvicorn` נעולים. התלויות שלהם לא נעולות, כך ששתי התקנות יכולות להיות שונות. קובץ נעילה יפתור את זה.
* לוג הבדיקות גדל בלי סוף. כלל של `logrotate` ימנע ממנו לגדול.
* כדאי להריץ את קובץ ה-`unit` על מכונה וירטואלית אמיתית עם `systemd`, ולא רק לבדוק את הקובץ.
