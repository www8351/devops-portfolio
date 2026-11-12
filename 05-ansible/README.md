# Ansible

## What this is

An Ansible playbook that prepares an Ubuntu 24.04 server and runs the app image on it as a container. ansible-lint and the syntax check pass. I ran the playbook twice inside an Ubuntu 24.04 container, with the tasks that need a real server skipped. I did not run it against AWS or against any other real server.

* `site.yml` is the playbook. It has one play for the group `app`. The play first checks that an image tag was given, then runs the roles `base`, `docker` and `app` in that order.
* `roles/base` updates the apt cache, installs a few packages, creates the service user `appuser` and sets up the firewall with ufw.
* `roles/docker` adds the Docker apt repository, installs the Docker engine and starts it.
* `roles/app` runs the image as a container and waits until `/health` answers.
* `group_vars/all.yml` holds the values the roles share: port, user, container name and image.
* `inventory.example.ini` is an example inventory for one server. The address comes from the Terraform output in `04-terraform/`.
* `requirements.yml` pins the two collections the playbook needs.
* `verify.sh` runs the whole check inside a throwaway Ubuntu 24.04 container.

These tasks ran in the container, in both runs:

```
Check that an image tag was given
base : Update the apt cache
base : Install the base packages
base : Create the service group
base : Create the service user
docker : Add the Docker apt repository
docker : Read the new Docker repository index before the install
```

The first run also ran the handler `docker : Refresh the apt cache`.

These tasks carry the tag `host_only`. They did not run in the test, where only ansible-lint and the syntax check cover them:

```
base : Allow SSH through the firewall
base : Allow the app port through the firewall
base : Deny incoming traffic by default
base : Enable the firewall
docker : Install the Docker engine
docker : Enable and start the Docker service
app : Run the app container
app : Wait until /health answers
```

## Why it is built this way

* One tag, `host_only`, marks the tasks that need netfilter, systemd or a running Docker engine, plus the engine install. The test skips them with `--skip-tags host_only`. Every other task has no tag and really ran.
* The firewall needs the kernel's netfilter, and a container without extra privileges cannot change it. I tried the ufw module in the test container. It runs `ufw status verbose` first, and even for a plain allow rule that failed with `Permission denied` from iptables. So all four firewall tasks carry the tag.
* SSH is allowed before the firewall is enabled, on the port Ansible connects on (`ansible_port`, 22 by default). In the other order, the firewall would block new SSH connections, including the ones Ansible opens.
* The Docker engine packages do install in a plain container. I tried it: the task `docker : Install the Docker engine` installed docker-ce, docker-ce-cli and containerd.io there. The engine cannot start there, though. dockerd stopped with `Permission denied` from iptables, and the service task failed with `Service is in unknown state`, because systemd does not run in a plain container. So the test leaves the engine out as a whole: the install and the service task carry the tag. The app tasks need a running engine, so they carry it too.
* CI tags each image with its commit SHA, as `ghcr.io/www8351/devops-portfolio:<commit sha>`. There is no fixed tag, so `app_image_tag` has no default. The play starts with an assert in `pre_tasks` that the tag was given, so a missing tag stops the run before anything on the server changes. The assert has no tag. The test passes the made up tag `verify-test`. It also runs the playbook once without a tag first and checks that it stops at the assert with nothing changed.
* The apt cache update has `cache_valid_time: 3600`, so it does nothing within an hour of the last update. Without it, the task would contact the mirrors on every run and report a change whenever they had published a new index in between.
* The Docker repository is written with `deb822_repository`. The module downloads Docker's key and puts its path into the entry as `Signed-By`, so apt trusts that key only for this repository. The suite comes from the distribution release fact, `noble` on Ubuntu 24.04. The architecture comes from a fact too, mapped to the Debian name, so `x86_64` becomes `amd64`. These tasks have no tag. In the test they wrote `/etc/apt/sources.list.d/docker.sources` and downloaded the key, and apt read the signed index from `download.docker.com`.
* A new repository is only useful once apt has read its index. The repository task notifies a handler that updates the apt cache, and `flush_handlers` runs it right away, before the engine install. When the repository has not changed, the handler does not run. That keeps the second run at zero changes. The engine install also refreshes the index itself. That covers a rerun after a first run that stopped between the repository and the refresh.
* The service user `appuser` gets uid and gid 10001, the same numbers the image runs as in `02-docker/Dockerfile`. The app process in the container would then show up as appuser on the host. As in the image, the home is `/nonexistent`, which is never created, and the shell is `/usr/sbin/nologin`.
* The container gets a read only root filesystem, no capabilities and `no-new-privileges`, the same limits as `02-docker/docker-compose.yml`. The restart policy `unless-stopped` brings it back after a reboot. The host port comes from `app_port` and maps to 8000 in the container.
* After the start, the `uri` module calls `/health` on 127.0.0.1 every 2 seconds, for about a minute, until it answers with status 200.
* The collections are pinned to exact versions: community.general 14.0.1 for ufw and community.docker 5.4.0 for docker_container.
* `verify.sh` installs ansible-core 2.21.6 and ansible-lint 26.11.0 in a venv. ansible-core 2.22 needs Python 3.13, and Ubuntu 24.04 has 3.12.3. 2.21.6 was the newest release that ran there when I wrote this.
* The test inventory points at the container itself: `localhost` with a local connection and no become, because the container already runs as root and has no sudo. It also sets `/usr/bin/python3` as the interpreter, the Python a server would use.
* After the first run, `verify.sh` checks the result: the packages are installed, appuser has the right uid, gid, home and shell, the Docker source file has the expected lines, and docker-ce has an install candidate from `download.docker.com`. It also checks that docker-ce is not installed and ufw is not enabled, so the tagged tasks really did not run. Then it checks that exactly the seven tasks above ran without a tag, and that exactly the eight tasks above carry it.
* Git ignores `inventory.ini`, because it holds a real address.

## How to run

All commands run from the repo root. I ran this one in PowerShell on Windows 11 with Docker Desktop. It needs network access to the Ubuntu archive, PyPI, Ansible Galaxy and `download.docker.com`. It took three to five minutes.

```
docker run --rm --name pf-ansible -v "${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash 05-ansible/verify.sh
```

ansible-lint ran with its default rules and printed `Passed: 0 failure(s), 0 warning(s)`, and the syntax check printed `playbook: site.yml`. The run without a tag stopped at the assert with `changed=0` and `failed=1`. The first run ended with `changed=5` and `failed=0`, the second with `changed=0` and `failed=0`. The last line was `VERIFY PASSED`.

I did not run the commands below on a real server or with a real Terraform output. They need a server built from `04-terraform/` and an image that CI has pushed. They also need a Linux or macOS control machine, because Ansible does not run on Windows itself. That machine needs Ansible, Terraform and the server's SSH key at `~/.ssh/my-key-pair.pem`. They run in bash from the repo root. The first line writes `inventory.ini` with the address from the Terraform output.

```
sed "s/APP_PUBLIC_IP/$(terraform -chdir=04-terraform output -raw public_ip)/" 05-ansible/inventory.example.ini > 05-ansible/inventory.ini
ansible-galaxy collection install -r 05-ansible/requirements.yml
ansible-playbook -i 05-ansible/inventory.ini 05-ansible/site.yml -e app_image_tag=<commit sha>
```

`<commit sha>` stands for the full SHA of a commit that CI pushed. The pinned collections need ansible-core 2.19 or newer on the control machine, because community.general 14.0.1 asks for `>=2.19.0`. `verify.sh` tests the first line with a stand-in for terraform that prints `203.0.113.10`, and ansible-inventory showed that address in the group `app`.

## What I would improve

* Seven of the eight `host_only` tasks have never run. The eighth, the engine install, ran once in a plain container, outside the test. A throwaway VM with systemd, or the server from `04-terraform/`, would test the firewall, the engine and the container for real.
* Docker's documentation says that published ports bypass the ufw rules, because Docker handles that traffic before it reaches the ufw chains. So ufw does not really guard the app port. The security group in `04-terraform/` does.
* The server pulls the image from GHCR without logging in. That only works while the package is public. A private package needs a `docker_login` task with a token kept in Ansible Vault.
* The image tag is typed by hand. The CI pipeline could run the playbook after the push, with its own commit SHA.
* Only ansible-core and ansible-lint are pinned in `verify.sh`. pip picks their dependencies, so two test runs can get different versions. A constraints file would fix that.
* The test stays on ansible-core 2.21 because of Python 3.12. Moving to 2.22 needs a control machine with Python 3.13 or newer.

---

# אנסיבל

## מה זה

קובץ `playbook` של `Ansible` שמכין שרת `Ubuntu 24.04` ומריץ עליו את האימג' של האפליקציה בתור קונטיינר. הבדיקות של `ansible-lint` ושל התחביר עוברות. הרצתי את ה-`playbook` פעמיים בתוך קונטיינר `Ubuntu 24.04`, בלי המשימות שצריכות שרת אמיתי. לא הרצתי אותו מול `AWS` ולא מול שום שרת אמיתי אחר.

* הקובץ `site.yml` הוא ה-`playbook`. יש בו `play` אחד לקבוצה `app`. ה-`play` בודק קודם שנמסר תג של אימג', ואחר כך מריץ את התפקידים `base`, `docker` ו-`app`, בסדר הזה.
* התפקיד `roles/base` מעדכן את ה-`cache` של `apt`, מתקין כמה חבילות, יוצר את חשבון השירות `appuser` ומגדיר חומת אש עם `ufw`.
* התפקיד `roles/docker` מוסיף את מאגר ה-`apt` של `Docker`, מתקין את מנוע `Docker` ומפעיל אותו.
* התפקיד `roles/app` מריץ את האימג' בתור קונטיינר ומחכה עד ש-`/health` עונה.
* הקובץ `group_vars/all.yml` מחזיק את הערכים שהתפקידים חולקים: פורט, חשבון, שם הקונטיינר והאימג'.
* הקובץ `inventory.example.ini` הוא דוגמה ל-`inventory` של שרת אחד. הכתובת מגיעה מהפלט של `Terraform` ב-`04-terraform/`.
* הקובץ `requirements.yml` נועל את שני ה-`collections` שה-`playbook` צריך.
* הסקריפט `verify.sh` מריץ את כל הבדיקה בתוך קונטיינר `Ubuntu 24.04` זמני.

המשימות האלה רצו בקונטיינר, בשתי ההרצות:

```
Check that an image tag was given
base : Update the apt cache
base : Install the base packages
base : Create the service group
base : Create the service user
docker : Add the Docker apt repository
docker : Read the new Docker repository index before the install
```

בהרצה הראשונה רץ גם ה-`handler` בשם `docker : Refresh the apt cache`.

המשימות האלה מסומנות בתג `host_only`. הן לא רצו בבדיקה, ושם רק `ansible-lint` ובדיקת התחביר בודקים אותן:

```
base : Allow SSH through the firewall
base : Allow the app port through the firewall
base : Deny incoming traffic by default
base : Enable the firewall
docker : Install the Docker engine
docker : Enable and start the Docker service
app : Run the app container
app : Wait until /health answers
```

## למה זה בנוי ככה

* תג אחד, `host_only`, מסמן את המשימות שצריכות `netfilter`, `systemd` או מנוע `Docker` שרץ, ובנוסף את ההתקנה של המנוע. הבדיקה מדלגת עליהן עם `--skip-tags host_only`. לכל שאר המשימות אין תג, והן באמת רצו.
* חומת האש צריכה את ה-`netfilter` של הקרנל, וקונטיינר בלי הרשאות נוספות לא יכול לשנות אותו. ניסיתי את המודול של `ufw` בקונטיינר הבדיקה. הוא מריץ קודם `ufw status verbose`, וגם עבור כלל `allow` פשוט זה נכשל עם `Permission denied` מ-`iptables`. לכן כל ארבע המשימות של חומת האש מסומנות בתג.
* חיבור `SSH` מותר לפני שחומת האש מופעלת, בפורט ש-`Ansible` מתחבר אליו (`ansible_port`, ו-`22` כברירת מחדל). בסדר ההפוך חומת האש הייתה חוסמת חיבורי `SSH` חדשים, כולל אלה ש-`Ansible` פותח.
* החבילות של מנוע `Docker` כן מותקנות בקונטיינר רגיל. ניסיתי את זה: המשימה `docker : Install the Docker engine` התקינה שם את `docker-ce`, את `docker-ce-cli` ואת `containerd.io`. אבל המנוע לא יכול להתחיל לפעול שם. התהליך `dockerd` נעצר עם `Permission denied` מ-`iptables`, והמשימה של השירות נכשלה עם `Service is in unknown state`, כי `systemd` לא רץ בקונטיינר רגיל. לכן הבדיקה משאירה את המנוע בחוץ לגמרי: ההתקנה והמשימה של השירות מסומנות בתג. המשימות של האפליקציה צריכות מנוע שרץ, ולכן גם הן מסומנות.
* מערכת ה-`CI` מתייגת כל אימג' ב-`SHA` של ה-`commit` שלו, בשם `ghcr.io/www8351/devops-portfolio:<commit sha>`. אין תג קבוע, ולכן ל-`app_image_tag` אין ברירת מחדל. ה-`play` מתחיל ב-`assert` בתוך `pre_tasks` שבודק שהתג נמסר, כך שתג חסר עוצר את ההרצה לפני שמשהו על השרת משתנה. ל-`assert` אין תג. הבדיקה מעבירה את התג המומצא `verify-test`. היא גם מריצה קודם את ה-`playbook` פעם אחת בלי תג, ובודקת שהוא נעצר ב-`assert` בלי לשנות כלום.
* לעדכון ה-`cache` של `apt` יש `cache_valid_time: 3600`, ולכן הוא לא עושה כלום בתוך שעה מהעדכון האחרון. בלי זה המשימה הייתה פונה לשרתי המראה בכל הרצה, ומדווחת על שינוי בכל פעם שהם פרסמו אינדקס חדש בינתיים.
* מאגר `Docker` נכתב עם `deb822_repository`. המודול מוריד את המפתח של `Docker` ושם את הנתיב שלו ברשומה בתור `Signed-By`, כך ש-`apt` סומך על המפתח הזה רק עבור המאגר הזה. ה-`suite` מגיע מה-`fact` של גרסת ההפצה, `noble` ב-`Ubuntu 24.04`. גם הארכיטקטורה מגיעה מ-`fact`, וממופה לשם של `Debian`, כך ש-`x86_64` הופך ל-`amd64`. למשימות האלה אין תג. בבדיקה הן כתבו את `/etc/apt/sources.list.d/docker.sources` והורידו את המפתח, והכלי `apt` קרא את האינדקס החתום מ-`download.docker.com`.
* מאגר חדש מועיל רק אחרי ש-`apt` קרא את האינדקס שלו. משימת המאגר מודיעה ל-`handler` שמעדכן את ה-`cache` של `apt`, והמשימה `flush_handlers` מריצה אותו מיד, לפני ההתקנה של המנוע. כשהמאגר לא השתנה, ה-`handler` לא רץ. כך ההרצה השנייה נשארת עם אפס שינויים. גם ההתקנה של המנוע מרעננת את האינדקס בעצמה. זה מכסה הרצה חוזרת אחרי הרצה ראשונה שנעצרה בין המאגר לבין הרענון.
* חשבון השירות `appuser` מקבל `uid` ו-`gid` של `10001`, אותם מספרים שהאימג' רץ איתם ב-`02-docker/Dockerfile`. התהליך של האפליקציה בקונטיינר היה מופיע אז על השרת בתור `appuser`. כמו באימג', תיקיית הבית היא `/nonexistent`, שאף פעם לא נוצרת, והמעטפת היא `/usr/sbin/nologin`.
* הקונטיינר מקבל מערכת קבצים לקריאה בלבד, בלי `capabilities` ועם `no-new-privileges`, אותן הגבלות כמו ב-`02-docker/docker-compose.yml`. מדיניות ההפעלה מחדש `unless-stopped` מחזירה אותו אחרי הפעלה מחדש של השרת. פורט השרת מגיע מ-`app_port` וממופה לפורט `8000` בקונטיינר.
* אחרי ההפעלה, המודול `uri` פונה ל-`/health` ב-`127.0.0.1` כל 2 שניות, במשך כדקה, עד שהוא עונה עם סטטוס `200`.
* הגרסאות של ה-`collections` נעולות במדויק: `community.general` בגרסה `14.0.1` בשביל `ufw`, ו-`community.docker` בגרסה `5.4.0` בשביל `docker_container`.
* הסקריפט `verify.sh` מתקין את `ansible-core 2.21.6` ואת `ansible-lint 26.11.0` בתוך `venv`. הגרסה `ansible-core 2.22` צריכה `Python 3.13`, וב-`Ubuntu 24.04` יש `3.12.3`. הגרסה `2.21.6` הייתה החדשה ביותר שרצה שם כשכתבתי את זה.
* קובץ ה-`inventory` של הבדיקה מצביע על הקונטיינר עצמו: `localhost` עם חיבור מקומי ובלי `become`, כי הקונטיינר כבר רץ בתור `root` ואין בו `sudo`. הוא גם קובע את `/usr/bin/python3` בתור המפרש, ה-`Python` שנמצא על שרת.
* אחרי ההרצה הראשונה, `verify.sh` בודק את התוצאה: החבילות מותקנות, ל-`appuser` יש את ה-`uid`, ה-`gid`, תיקיית הבית והמעטפת הנכונים, בקובץ המאגר של `Docker` יש את השורות הצפויות, ול-`docker-ce` יש מועמד להתקנה מ-`download.docker.com`. הוא גם בודק ש-`docker-ce` לא מותקן ושחומת האש של `ufw` לא מופעלת, כלומר המשימות המסומנות באמת לא רצו. אחר כך הוא בודק שבדיוק שבע המשימות שלמעלה רצו בלי תג, ושבדיוק שמונה המשימות שלמעלה מסומנות בתג.
* הכלי `git` מתעלם מ-`inventory.ini`, כי הוא מחזיק כתובת אמיתית.

## איך מריצים

כל הפקודות רצות משורש הריפו. את הפקודה הזאת הרצתי ב-`PowerShell` על `Windows 11` עם `Docker Desktop`. היא צריכה גישה לרשת: לארכיון של `Ubuntu`, ל-`PyPI`, ל-`Ansible Galaxy` ול-`download.docker.com`. היא לקחה בין שלוש לחמש דקות.

```
docker run --rm --name pf-ansible -v "${PWD}:/repo:ro" -w /repo ubuntu:24.04 bash 05-ansible/verify.sh
```

הכלי `ansible-lint` רץ עם כללי ברירת המחדל שלו והדפיס `Passed: 0 failure(s), 0 warning(s)`, ובדיקת התחביר הדפיסה `playbook: site.yml`. ההרצה בלי תג נעצרה ב-`assert` עם `changed=0` ו-`failed=1`. ההרצה הראשונה הסתיימה עם `changed=5` ו-`failed=0`, והשנייה עם `changed=0` ו-`failed=0`. השורה האחרונה הייתה `VERIFY PASSED`.

לא הרצתי את הפקודות שלמטה מול שרת אמיתי או עם פלט אמיתי של `Terraform`. הן צריכות שרת שנבנה מ-`04-terraform/` ואימג' שה-`CI` דחף. הן צריכות גם מחשב שליטה עם `Linux` או `macOS`, כי `Ansible` עצמו לא רץ על `Windows`. על המחשב הזה צריך את `Ansible`, את `Terraform` ואת מפתח ה-`SSH` של השרת ב-`~/.ssh/my-key-pair.pem`. מריצים אותן ב-`bash` משורש הריפו. השורה הראשונה כותבת את `inventory.ini` עם הכתובת מהפלט של `Terraform`.

```
sed "s/APP_PUBLIC_IP/$(terraform -chdir=04-terraform output -raw public_ip)/" 05-ansible/inventory.example.ini > 05-ansible/inventory.ini
ansible-galaxy collection install -r 05-ansible/requirements.yml
ansible-playbook -i 05-ansible/inventory.ini 05-ansible/site.yml -e app_image_tag=<commit sha>
```

הביטוי `<commit sha>` מייצג את ה-`SHA` המלא של `commit` שה-`CI` דחף. שני ה-`collections` הנעולים צריכים `ansible-core 2.19` ומעלה על מחשב השליטה, כי `community.general 14.0.1` דורש `>=2.19.0`. הסקריפט `verify.sh` בודק את השורה הראשונה עם תחליף ל-`terraform` שמדפיס את `203.0.113.10`, והפקודה `ansible-inventory` הראתה את הכתובת הזאת בקבוצה `app`.

## מה הייתי רוצה לשפר

* שבע מתוך שמונה המשימות של `host_only` לא רצו אף פעם. השמינית, ההתקנה של המנוע, רצה פעם אחת בקונטיינר רגיל, מחוץ לבדיקה. מכונה וירטואלית זמנית עם `systemd`, או השרת מ-`04-terraform/`, תבדוק באמת את חומת האש, את המנוע ואת הקונטיינר.
* לפי התיעוד של `Docker`, פורטים שממופים החוצה עוקפים את הכללים של `ufw`, כי `Docker` מטפל בתעבורה הזאת לפני שהיא מגיעה לשרשראות של `ufw`. לכן `ufw` לא באמת שומר על פורט האפליקציה. קבוצת האבטחה ב-`04-terraform/` כן שומרת עליו.
* השרת מושך את האימג' מ-`GHCR` בלי להתחבר. זה עובד רק כל עוד החבילה ציבורית. חבילה פרטית צריכה משימת `docker_login` עם `token` ששמור ב-`Ansible Vault`.
* תג האימג' מוקלד ביד. צנרת ה-`CI` יכולה להריץ את ה-`playbook` אחרי הדחיפה, עם ה-`SHA` של ה-`commit` שלה.
* רק `ansible-core` ו-`ansible-lint` נעולים ב-`verify.sh`. הכלי `pip` בוחר את התלויות שלהם, כך ששתי הרצות של הבדיקה יכולות לקבל גרסאות שונות. קובץ `constraints` יפתור את זה.
* הבדיקה נשארת על `ansible-core 2.21` בגלל `Python 3.12`. מעבר ל-`2.22` צריך מחשב שליטה עם `Python 3.13` ומעלה.
