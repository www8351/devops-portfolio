# Kubernetes

## What this is

Four plain manifests that run the app image on Kubernetes: a Deployment with two pods behind a Service. I validated them with kubeconform and applied them to a local k3d cluster on my machine. The rollout completed, `/health` answered through a port-forward, and a pod I deleted was replaced by a new one. Then I deleted the cluster. The image was imported from the local Docker image store, not pulled from a registry. I did not run this on any cloud or on a real cluster.

* `00-namespace.yaml` creates the namespace `portfolio` and turns on the restricted Pod Security level for it.
* `01-configmap.yaml` holds `APP_VERSION`, the value `/version` reports.
* `02-deployment.yaml` runs two pods from `portfolio-app:0.1.0`, with readiness and liveness probes on `/health`, resource requests and limits, and a locked down security context.
* `03-service.yaml` gives the two pods one address inside the cluster. Port 80 goes to port 8000 in the container.

## Why it is built this way

* The number prefixes set the order. `kubectl apply -f 06-kubernetes/` reads the files in name order, so the namespace exists before anything goes into it. One command applies all four to an empty cluster. On a fresh cluster it printed four `created` lines.
* The namespace has the label `pod-security.kubernetes.io/enforce: restricted`. The API server then refuses any pod there that could run as root, keep Linux capabilities or gain more privileges. I tried it: a pod with `runAsUser: 0` was refused with `violates PodSecurity "restricted:latest"`, and nothing was created.
* The Deployment meets that level. The pod runs as user and group 10001, with `runAsNonRoot: true` and the `RuntimeDefault` seccomp profile. The container cannot escalate privileges, has a read only root filesystem and drops all capabilities. These are the same numbers and limits as in `02-docker/Dockerfile` and `02-docker/docker-compose.yml`. In a pod, `id` printed `uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)`, and writing a file in /tmp failed with `Read-only file system`.
* `automountServiceAccountToken` is false, because the app never calls the Kubernetes API. So the pod holds no token that someone could steal. `/var/run/secrets/kubernetes.io` did not exist in the pod.
* Kubernetes ignores the HEALTHCHECK in the image. The two probes do that job. Readiness calls `/health` every 5 seconds and takes the pod out of the Service after 3 failures in a row. Liveness calls it every 10 seconds, starting 10 seconds after the container starts, and restarts the container after 3 failures. After the apply, `get pods` showed both pods ready at an age of 7 seconds.
* Each pod asks for 50m CPU and 64Mi memory and may use up to 250m CPU and 128Mi memory. The scheduler reserves the requests on a node. The limits stop one pod that goes wrong from taking the whole node.
* The version sits in a ConfigMap and reaches the container through `envFrom`. A new value needs a restart, not a new image. I tested it: I patched the value to `gate-check`, restarted the Deployment, and `/version` answered `{"version":"gate-check"}`. The file still says 0.1.0.
* There are two replicas, with `maxUnavailable: 0` and `maxSurge: 1`. In a rollout, a new pod has to be ready before an old one stops, so at least two ready pods stay behind the Service.
* The image is `portfolio-app:0.1.0` with `imagePullPolicy: IfNotPresent`. It is in no registry. `k3d image import` copies it from the local Docker image store into the cluster node, and the kubelet finds it there. With `Always`, the kubelet would try a registry first.
* The Service is a ClusterIP. Only the cluster can reach it. For the test I reached it with `kubectl port-forward`. There is no Ingress yet.
* Plain YAML, no Helm and no Kustomize. For one app in one environment, four short files are easier to read than a template.
* k3d runs k3s inside Docker containers. Creating the cluster took a little over two minutes here, and deleting it took about a second.
* The cluster is created with `--kubeconfig-update-default=false`, and its kubeconfig goes to `06-kubernetes/.kubeconfig`. Git ignores that file. It has no `.yaml` ending on purpose. `kubectl apply -f` and kubeconform read only `.yaml`, `.yml` and `.json` files from a folder, so they leave it alone. With the file in the folder, `apply` printed exactly four objects.

## How to run

All commands run from the repo root. I ran them in PowerShell 7 on Windows 11 with Docker Desktop, k3d 5.9.0, which runs k3s v1.35.5+k3s1, and kubectl 1.36.1. Every kubectl command gets `--kubeconfig 06-kubernetes/.kubeconfig`, so it talks to this cluster and the default kubeconfig in the home folder stays untouched.

Validate the manifests:

```
docker run --rm -v "${PWD}/06-kubernetes:/manifests:ro" ghcr.io/yannh/kubeconform:v0.8.0 -strict -summary /manifests
```

It printed `Summary: 4 resources found in 4 files - Valid: 4, Invalid: 0, Errors: 0, Skipped: 0`. With `-strict`, a field the schema does not know counts as an error too. kubeconform downloads the schemas, so it needs network access.

Create the cluster, write its kubeconfig into this folder and check the node:

```
k3d cluster create portfolio --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait --timeout 300s
k3d kubeconfig write portfolio --output 06-kubernetes/.kubeconfig
kubectl --kubeconfig 06-kubernetes/.kubeconfig get nodes
```

The node `k3d-portfolio-server-0` was `Ready`.

Import the image from the local Docker image store and check that the node has it:

```
k3d image import portfolio-app:0.1.0 -c portfolio
docker exec k3d-portfolio-server-0 crictl images
```

The import printed `Successfully imported 1 image(s) into 1 cluster(s)`, and `crictl` listed `docker.io/library/portfolio-app` with the tag `0.1.0`. On this machine Docker Desktop uses the containerd image store, and the import worked without extra steps.

Apply the four manifests and wait for the rollout:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig apply -f 06-kubernetes/
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout status deployment/portfolio-app --timeout=180s
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio get pods -o wide
```

`apply` printed four lines, from `namespace/portfolio created` to `service/portfolio-app created`. `rollout status` ended with `deployment "portfolio-app" successfully rolled out`. Both pods were `Running` and ready, `1/1`.

Call the app through the Service. `port-forward` runs until it is stopped, so it needs its own terminal. I ran it in the background and stopped it after the calls.

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio port-forward svc/portfolio-app 8080:80
```

```
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/version
```

They answered `{"status":"ok"}` and `{"version":"0.1.0"}`.

Delete one pod and check that the Deployment replaces it. The pod name comes from the first command and is different on every run:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio get pods
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio delete pod portfolio-app-5747cdbcc9-h7f9p
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout status deployment/portfolio-app --timeout=180s
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio get pods
```

Before, the pods were `portfolio-app-5747cdbcc9-h7f9p` and `portfolio-app-5747cdbcc9-r26fs`. After, they were `portfolio-app-5747cdbcc9-r26fs` and the new `portfolio-app-5747cdbcc9-wps6q`, both `Running` and ready, `1/1`.

Check the user inside a pod:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio exec deploy/portfolio-app -- id
```

It printed `uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)`.

Show that `/version` reads the ConfigMap. This changes the value in the cluster only, and the file keeps 0.1.0. In PowerShell 7 the JSON after `-p` goes through as written.

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio patch configmap portfolio-app --type merge -p '{"data":{"APP_VERSION":"gate-check"}}'
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout restart deployment/portfolio-app
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout status deployment/portfolio-app --timeout=180s
```

When the old pods were gone, I started the port-forward again, and `curl -s http://127.0.0.1:8080/version` answered `{"version":"gate-check"}`.

Try to start a pod as root in the namespace:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio run pf-probe --image=portfolio-app:0.1.0 --restart=Never --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":0}}}'
```

The API server refused it with `Error from server (Forbidden)` and `violates PodSecurity "restricted:latest"`. The message listed five problems, among them `runAsUser=0 (pod must not set runAsUser=0)`. No pod was created.

Delete the cluster and check that nothing is left:

```
k3d cluster delete portfolio
k3d cluster list
docker ps -a --filter name=k3d-portfolio
```

`cluster list` showed no cluster, and `docker ps` listed no container. k3d also tried to remove the cluster from the default kubeconfig and warned that `~/.kube/config` does not exist, so that file was never written. Then I deleted `06-kubernetes/.kubeconfig`.

## What I would improve

* I picked the resource numbers by hand and did not measure what the app really uses. A metrics server and `kubectl top` would show it.
* kubeconform checks against the schemas of the Kubernetes master branch by default. I would pin `-kubernetes-version` to the version the cluster runs.
* The image is imported by hand. On a real cluster the Deployment would pull the image CI would push to GHCR, tagged with the commit SHA.
* I did not test a rollout with a broken image or a failing probe. With `maxUnavailable: 0` the old pods should keep answering, but I have not seen it.
* There is no PodDisruptionBudget and no NetworkPolicy. A node drain could stop both pods at once, and any pod in the cluster can reach the app.
* The Service is only reachable through `port-forward`. An Ingress with TLS would make it reachable from outside.

---

# קוברנטיס

## מה זה

ארבעה קובצי `manifest` פשוטים שמריצים את האימג' של האפליקציה ב-`Kubernetes`: משאב `Deployment` עם שני `pods` מאחורי `Service`. בדקתי אותם עם `kubeconform` והחלתי אותם על קלאסטר `k3d` מקומי במחשב שלי. ה-`rollout` הסתיים, הנתיב `/health` ענה דרך `port-forward`, ו-`pod` שמחקתי הוחלף ב-`pod` חדש. אחר כך מחקתי את הקלאסטר. האימג' יובא ממאגר האימג'ים המקומי של `Docker`, ולא נמשך מ-`registry`. לא הרצתי את זה בשום ענן ולא על קלאסטר אמיתי.

* הקובץ `00-namespace.yaml` יוצר את ה-`namespace` בשם `portfolio` ומפעיל עליו את רמת ה-`Pod Security` המחמירה, `restricted`.
* הקובץ `01-configmap.yaml` מחזיק את `APP_VERSION`, הערך שהנתיב `/version` מחזיר.
* הקובץ `02-deployment.yaml` מריץ שני `pods` מהאימג' `portfolio-app:0.1.0`, עם בדיקות `readiness` ו-`liveness` על `/health`, עם `requests` ו-`limits` למשאבים, ועם `security context` נעול.
* הקובץ `03-service.yaml` נותן לשני ה-`pods` כתובת אחת בתוך הקלאסטר. פורט `80` מועבר לפורט `8000` בקונטיינר.

## למה זה בנוי ככה

* המספרים בתחילת שמות הקבצים קובעים את הסדר. הפקודה `kubectl apply -f 06-kubernetes/` קוראת את הקבצים לפי סדר השמות, כך שה-`namespace` קיים לפני שמשהו נכנס אליו. פקודה אחת מחילה את כל הארבעה על קלאסטר ריק. על קלאסטר חדש היא הדפיסה ארבע שורות `created`.
* התווית `pod-security.kubernetes.io/enforce: restricted` מוצמדת ל-`namespace`. בגללה שרת ה-`API` דוחה שם כל `pod` שיכול לרוץ בתור `root`, להשאיר `capabilities` של `Linux` או לקבל הרשאות נוספות. ניסיתי את זה: `pod` עם `runAsUser: 0` נדחה עם `violates PodSecurity "restricted:latest"`, ושום דבר לא נוצר.
* המשאב `Deployment` עומד ברמה הזאת. ה-`pod` רץ תחת חשבון `10001` וקבוצה `10001`, עם `runAsNonRoot: true` ועם פרופיל ה-`seccomp` בשם `RuntimeDefault`. הקונטיינר לא יכול להסלים הרשאות, מערכת הקבצים שלו היא לקריאה בלבד, וכל ה-`capabilities` שלו מוסרות. אלה אותם מספרים ואותן הגבלות כמו ב-`02-docker/Dockerfile` וב-`02-docker/docker-compose.yml`. בתוך `pod` הפקודה `id` הדפיסה `uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)`, וכתיבה של קובץ ב-`/tmp` נכשלה עם `Read-only file system`.
* ההגדרה `automountServiceAccountToken` כבויה, כי האפליקציה אף פעם לא פונה ל-`API` של `Kubernetes`. כך אין ב-`pod` שום `token` שמישהו יכול לגנוב. התיקייה `/var/run/secrets/kubernetes.io` לא הייתה קיימת ב-`pod`.
* המערכת `Kubernetes` מתעלמת מה-`HEALTHCHECK` שבאימג'. שתי הבדיקות עושות את העבודה הזאת. בדיקת ה-`readiness` פונה ל-`/health` כל 5 שניות, ומוציאה את ה-`pod` מה-`Service` אחרי 3 כישלונות ברצף. בדיקת ה-`liveness` פונה אליו כל 10 שניות, החל מ-10 שניות אחרי שהקונטיינר עלה, ומפעילה את הקונטיינר מחדש אחרי 3 כישלונות. אחרי ה-`apply`, הפקודה `get pods` הראתה את שני ה-`pods` מוכנים בגיל של 7 שניות.
* כל `pod` מבקש `50m` של `CPU` ו-`64Mi` של זיכרון, ויכול להשתמש בעד `250m` של `CPU` ו-`128Mi` של זיכרון. ה-`scheduler` שומר את ה-`requests` על ה-`node`. ה-`limits` מונעים מ-`pod` אחד שמשתבש לתפוס את כל ה-`node`.
* הגרסה יושבת ב-`ConfigMap` ומגיעה לקונטיינר דרך `envFrom`. ערך חדש צריך הפעלה מחדש, לא אימג' חדש. בדקתי את זה: שיניתי את הערך ל-`gate-check`, הפעלתי מחדש את ה-`Deployment`, והנתיב `/version` ענה `{"version":"gate-check"}`. בקובץ עדיין כתוב `0.1.0`.
* יש שני עותקים (`replicas`), עם `maxUnavailable: 0` ועם `maxSurge: 1`. בזמן `rollout`, `pod` חדש צריך להיות מוכן לפני ש-`pod` ישן נעצר, כך שלפחות שני `pods` מוכנים נשארים מאחורי ה-`Service`.
* האימג' הוא `portfolio-app:0.1.0` עם `imagePullPolicy: IfNotPresent`. הוא לא נמצא בשום `registry`. הפקודה `k3d image import` מעתיקה אותו ממאגר האימג'ים המקומי של `Docker` אל ה-`node` של הקלאסטר, וה-`kubelet` מוצא אותו שם. עם `Always`, ה-`kubelet` היה מנסה קודם `registry`.
* הסוג של ה-`Service` הוא `ClusterIP`. רק מתוך הקלאסטר אפשר להגיע אליו. בבדיקה הגעתי אליו עם `kubectl port-forward`. עדיין אין `Ingress`.
* רק `YAML` פשוט, בלי `Helm` ובלי `Kustomize`. לאפליקציה אחת בסביבה אחת, ארבעה קבצים קצרים קלים יותר לקריאה מתבנית.
* הכלי `k3d` מריץ את `k3s` בתוך קונטיינרים של `Docker`. יצירת הקלאסטר לקחה כאן קצת יותר משתי דקות, והמחיקה שלו לקחה בערך שנייה.
* הקלאסטר נוצר עם `--kubeconfig-update-default=false`, וה-`kubeconfig` שלו נכתב ל-`06-kubernetes/.kubeconfig`. הכלי `git` מתעלם מהקובץ הזה. אין לו סיומת `.yaml` בכוונה. הפקודה `kubectl apply -f` והכלי `kubeconform` קוראים מתיקייה רק קבצי `.yaml`, `.yml` ו-`.json`, ולכן הם לא נוגעים בו. כשהקובץ היה בתיקייה, הפקודה `apply` הדפיסה בדיוק ארבעה אובייקטים.

## איך מריצים

כל הפקודות רצות משורש הריפו. הרצתי אותן ב-`PowerShell 7` על `Windows 11` עם `Docker Desktop`, עם `k3d 5.9.0` שמריץ את `k3s v1.35.5+k3s1`, ועם `kubectl 1.36.1`. כל פקודת `kubectl` מקבלת `--kubeconfig 06-kubernetes/.kubeconfig`, כך שהיא מדברת עם הקלאסטר הזה וה-`kubeconfig` של ברירת המחדל בתיקיית הבית לא משתנה.

בודקים את קובצי ה-`manifest`:

```
docker run --rm -v "${PWD}/06-kubernetes:/manifests:ro" ghcr.io/yannh/kubeconform:v0.8.0 -strict -summary /manifests
```

הפקודה הדפיסה `Summary: 4 resources found in 4 files - Valid: 4, Invalid: 0, Errors: 0, Skipped: 0`. עם `-strict`, גם שדה שה-`schema` לא מכיר נחשב לשגיאה. הכלי `kubeconform` מוריד את ה-`schemas`, ולכן הוא צריך גישה לרשת.

יוצרים את הקלאסטר, כותבים את ה-`kubeconfig` שלו לתיקייה הזאת ובודקים את ה-`node`:

```
k3d cluster create portfolio --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait --timeout 300s
k3d kubeconfig write portfolio --output 06-kubernetes/.kubeconfig
kubectl --kubeconfig 06-kubernetes/.kubeconfig get nodes
```

המצב של `k3d-portfolio-server-0` היה `Ready`.

מייבאים את האימג' ממאגר האימג'ים המקומי של `Docker` ובודקים שהוא נמצא ב-`node`:

```
k3d image import portfolio-app:0.1.0 -c portfolio
docker exec k3d-portfolio-server-0 crictl images
```

הייבוא הדפיס `Successfully imported 1 image(s) into 1 cluster(s)`, והכלי `crictl` הציג את `docker.io/library/portfolio-app` עם התג `0.1.0`. במחשב הזה `Docker Desktop` עובד עם מאגר האימג'ים של `containerd`, והייבוא עבד בלי צעדים נוספים.

מחילים את ארבעת הקבצים ומחכים ל-`rollout`:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig apply -f 06-kubernetes/
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout status deployment/portfolio-app --timeout=180s
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio get pods -o wide
```

הפקודה `apply` הדפיסה ארבע שורות, מ-`namespace/portfolio created` ועד `service/portfolio-app created`. הפקודה `rollout status` הסתיימה ב-`deployment "portfolio-app" successfully rolled out`. שני ה-`pods` היו במצב `Running` ומוכנים, `1/1`.

פונים לאפליקציה דרך ה-`Service`. הפקודה `port-forward` רצה עד שעוצרים אותה, ולכן היא צריכה טרמינל משלה. הרצתי אותה ברקע ועצרתי אותה אחרי הקריאות.

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio port-forward svc/portfolio-app 8080:80
```

```
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/version
```

התשובות היו `{"status":"ok"}` ו-`{"version":"0.1.0"}`.

מוחקים `pod` אחד ובודקים שה-`Deployment` מחליף אותו. שם ה-`pod` מגיע מהפקודה הראשונה, והוא שונה בכל הרצה:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio get pods
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio delete pod portfolio-app-5747cdbcc9-h7f9p
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout status deployment/portfolio-app --timeout=180s
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio get pods
```

לפני המחיקה ה-`pods` היו `portfolio-app-5747cdbcc9-h7f9p` ו-`portfolio-app-5747cdbcc9-r26fs`. אחרי המחיקה הם היו `portfolio-app-5747cdbcc9-r26fs` וה-`pod` החדש `portfolio-app-5747cdbcc9-wps6q`, שניהם במצב `Running` ומוכנים, `1/1`.

בודקים את החשבון בתוך `pod`:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio exec deploy/portfolio-app -- id
```

הפקודה הדפיסה `uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)`.

מראים שהנתיב `/version` קורא את ה-`ConfigMap`. זה משנה את הערך רק בקלאסטר, והקובץ נשאר עם `0.1.0`. ב-`PowerShell 7` ה-`JSON` שאחרי `-p` עובר כמו שהוא כתוב.

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio patch configmap portfolio-app --type merge -p '{"data":{"APP_VERSION":"gate-check"}}'
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout restart deployment/portfolio-app
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio rollout status deployment/portfolio-app --timeout=180s
```

אחרי שה-`pods` הישנים נעלמו, הפעלתי שוב את ה-`port-forward`, והפקודה `curl -s http://127.0.0.1:8080/version` ענתה `{"version":"gate-check"}`.

מנסים להפעיל `pod` בתור `root` ב-`namespace`:

```
kubectl --kubeconfig 06-kubernetes/.kubeconfig -n portfolio run pf-probe --image=portfolio-app:0.1.0 --restart=Never --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsUser":0}}}'
```

שרת ה-`API` דחה אותו עם `Error from server (Forbidden)` ועם `violates PodSecurity "restricted:latest"`. ההודעה מנתה חמש בעיות, ביניהן `runAsUser=0 (pod must not set runAsUser=0)`. שום `pod` לא נוצר.

מוחקים את הקלאסטר ובודקים ששום דבר לא נשאר:

```
k3d cluster delete portfolio
k3d cluster list
docker ps -a --filter name=k3d-portfolio
```

הפקודה `cluster list` לא הציגה אף קלאסטר, והפקודה `docker ps` לא הציגה אף קונטיינר. הכלי `k3d` גם ניסה להסיר את הקלאסטר מה-`kubeconfig` של ברירת המחדל, והזהיר שהקובץ `~/.kube/config` לא קיים, כלומר הקובץ הזה אף פעם לא נכתב. בסוף מחקתי את `06-kubernetes/.kubeconfig`.

## מה הייתי רוצה לשפר

* בחרתי את מספרי המשאבים ביד, ולא מדדתי כמה האפליקציה באמת צורכת. שרת `metrics` והפקודה `kubectl top` יראו את זה.
* הכלי `kubeconform` בודק כברירת מחדל מול ה-`schemas` של ענף ה-`master` של `Kubernetes`. כדאי לנעול את `-kubernetes-version` לגרסה שהקלאסטר מריץ.
* האימג' מיובא ביד. בקלאסטר אמיתי ה-`Deployment` היה מושך את האימג' שה-`CI` היה דוחף ל-`GHCR`, עם התג של ה-`SHA` של ה-`commit`.
* לא בדקתי `rollout` עם אימג' שבור או עם בדיקה שנכשלת. עם `maxUnavailable: 0` ה-`pods` הישנים אמורים להמשיך לענות, אבל לא ראיתי את זה.
* אין `PodDisruptionBudget` ואין `NetworkPolicy`. ריקון של `node` יכול לעצור את שני ה-`pods` בבת אחת, וכל `pod` בקלאסטר יכול להגיע לאפליקציה.
* אפשר להגיע ל-`Service` רק דרך `port-forward`. רכיב `Ingress` עם `TLS` יאפשר להגיע אליו מבחוץ.
