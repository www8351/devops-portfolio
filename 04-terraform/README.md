# Terraform

## What this is

Terraform code for one small EC2 instance on AWS, a server the app could run on, and the security group around it. I checked the code with `terraform fmt`, `terraform init` without a backend and `terraform validate`. I did not run plan or apply, so this code has never created anything.

* `versions.tf` sets the Terraform version range and pins the AWS provider.
* `variables.tf` holds the inputs: region, instance type, `my_ip`, key pair name and app port.
* `main.tf` has the provider, the Ubuntu 24.04 image lookup, the default VPC, the security group with its rules and the instance.
* `outputs.tf` prints the public IP and an SSH command.
* `terraform.tfvars.example` has sample values.
* `.terraform.lock.hcl` records the provider version and its checksums. `terraform init` wrote it.

## Why it is built this way

* The AWS provider is pinned to one exact version, `= 6.73.0`, the newest release when I wrote this. A new provider release can change how a resource behaves. With the pin, that only happens when someone changes the line. The lock file keeps the checksums of that release, and `init` checks the download against them.
* Terraform itself gets a range, `>= 1.9, < 2.0`. I only ran 1.17.2. A 2.0 release may change the language, so the range stops before it.
* The instance type is a variable with the default `t3.micro`. A bigger server is one line in `terraform.tfvars`.
* The security group lets in two things. SSH on port 22 comes only from `my_ip`, as a /32. The app port, 8000 by default, is open to everyone, because that is where the app answers. All outbound traffic is allowed, so the server can download packages and the app image.
* `my_ip` has a validation rule: four numbers from 0 to 255 with dots between them, and nothing else. The code adds the `/32` itself, so `203.0.113.10/32` would become `203.0.113.10/32/32`. The rule rejects that, and also text like `abc`. Terraform checks the rule once it gets a value, at plan time, and I did not run a plan. I tested the same pattern in Python: it accepted `203.0.113.10` and rejected `203.0.113.10/32` and `abc`.
* `app_port` has a validation rule too: a whole number from 1 to 65535, and not 22, because the app port is open to everyone and 22 would open SSH to everyone as well. As with `my_ip`, Terraform checks this rule at plan time, and I did not run a plan.
* Each rule is its own resource (`aws_vpc_security_group_ingress_rule`, `aws_vpc_security_group_egress_rule`), not a block inside the group. Each one has its own description, and a change to one rule leaves the others alone. Terraform removes the default outbound rule of a new group, so the outbound rule is written out.
* The image is the newest Ubuntu 24.04 amd64 server image owned by Canonical's account `099720109477`. The owner filter means an image that someone else published under a similar name is never picked. The default login on these images is `ubuntu`, and `ssh_command` uses it.
* The instance requires IMDSv2 (`http_tokens = "required"`). A request to the metadata service needs a session token first, which blocks the simple way to read the instance credentials through a forged request. The root volume is gp3 and encrypted.
* The instance asks for a public IP itself (`associate_public_ip_address = true`), so the outputs do not depend on how the default subnet is set.
* I used the default VPC, so there is no network of my own to build.
* `default_tags` in the provider puts `Project = "devops-portfolio"` and `ManagedBy = "terraform"` on every resource. The instance is also named `portfolio-app`.
* `public_ip` holds only the address, so a script can read it with `terraform output -raw public_ip`.
* Git ignores `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars` and `*.tfvars.json`. The state holds every attribute of the resources, and `terraform.tfvars` holds a real address and key name. The example file ends in `.example`, so git keeps it. The lock file is tracked too, because it is part of the pin. I checked all of this with `git check-ignore -v`.

## How to run

All commands run from the repo root. I ran them in PowerShell on Windows 11 with Docker Desktop and the image `hashicorp/terraform:1.17.2`. None of them needs AWS credentials.

Check the formatting:

```
docker run --rm -v "${PWD}/04-terraform:/tf" -w /tf hashicorp/terraform:1.17.2 fmt -check -recursive -diff
```

It printed nothing and exited with code 0.

Install the provider, without a backend:

```
docker run --rm -v "${PWD}/04-terraform:/tf" -w /tf hashicorp/terraform:1.17.2 init -backend=false -input=false
```

It printed `Installed hashicorp/aws v6.73.0 (signed by HashiCorp)` and `Terraform has been successfully initialized!`. It took about a minute. The provider fills about 770 MB in `04-terraform/.terraform/`, and git ignores that folder.

Validate the code:

```
docker run --rm -v "${PWD}/04-terraform:/tf" -w /tf hashicorp/terraform:1.17.2 validate
```

It printed `Success! The configuration is valid.`

I did not run the commands below. They create a real server in an AWS account and need AWS credentials. With an AWS account, credentials, an existing key pair and Terraform installed, they run from `04-terraform/`. After the copy, `terraform.tfvars` needs a real address and key pair name.

```
cd 04-terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
terraform output
```

I did not run `terraform destroy` either. It removes everything again.

## What I would improve

* Keep the state in a remote backend with locking, such as an S3 bucket. As it is, the state would be a local file on one machine, and nothing stops two people from running apply at the same time.
* Build a small VPC and subnet of its own. Some accounts have no default VPC, and then this code fails.
* The public IP changes when the instance stops and starts again. An Elastic IP would keep it.
* Test the `my_ip` rule and the outputs with `terraform test` and a mocked provider, so Terraform itself checks them without AWS.
* The lock file has the full `h1` checksum only for `linux_amd64`, where init ran. An init on Windows or macOS adds a line to it. `terraform providers lock` for those platforms would add them up front.
* The app port is open to everyone and speaks plain HTTP. A load balancer with TLS in front of it would fix that.

---

# טרפורם

## מה זה

קוד `Terraform` לשרת `EC2` קטן אחד ב-`AWS`, שרת שהאפליקציה יכולה לרוץ עליו, ולקבוצת האבטחה (`security group`) שמסביבו. בדקתי את הקוד עם `terraform fmt`, עם `terraform init` בלי `backend` ועם `terraform validate`. לא הרצתי `plan` ולא `apply`, ולכן הקוד הזה לא יצר אף פעם שום דבר.

* הקובץ `versions.tf` קובע את טווח הגרסאות של `Terraform` ונועל את ה-`provider` של `AWS`.
* הקובץ `variables.tf` מחזיק את הקלטים: אזור, סוג שרת, `my_ip`, שם של `key pair` ופורט האפליקציה.
* הקובץ `main.tf` מכיל את ה-`provider`, את החיפוש של אימג' `Ubuntu 24.04`, את ה-`VPC` של ברירת המחדל, את קבוצת האבטחה עם הכללים שלה ואת השרת.
* הקובץ `outputs.tf` מדפיס את כתובת ה-`IP` הציבורית ופקודת `SSH`.
* הקובץ `terraform.tfvars.example` מכיל ערכים לדוגמה.
* הקובץ `.terraform.lock.hcl` רושם את גרסת ה-`provider` ואת ה-`checksums` שלה. הפקודה `terraform init` כתבה אותו.

## למה זה בנוי ככה

* רכיב ה-`provider` של `AWS` נעול לגרסה מדויקת אחת, `= 6.73.0`, הגרסה החדשה ביותר כשכתבתי את הקוד. גרסה חדשה של ה-`provider` יכולה לשנות את ההתנהגות של משאב. עם הנעילה, זה קורה רק כשמישהו משנה את השורה. קובץ הנעילה שומר את ה-`checksums` של הגרסה הזאת, והפקודה `init` בודקת את ההורדה מולם.
* לכלי `Terraform` עצמו יש טווח, `>= 1.9, < 2.0`. הרצתי רק את `1.17.2`. גרסה `2.0` עלולה לשנות את השפה, ולכן הטווח נעצר לפניה.
* סוג השרת הוא משתנה, עם ברירת המחדל `t3.micro`. שרת גדול יותר הוא שורה אחת ב-`terraform.tfvars`.
* קבוצת האבטחה מכניסה שני דברים. חיבור `SSH` בפורט `22` מגיע רק מ-`my_ip`, בתור `/32`. פורט האפליקציה, `8000` כברירת מחדל, פתוח לכולם, כי שם האפליקציה עונה. כל התעבורה היוצאת מותרת, כדי שהשרת יוכל להוריד חבילות ואת האימג' של האפליקציה.
* למשתנה `my_ip` יש כלל אימות: ארבעה מספרים מ-0 עד 255 עם נקודות ביניהם, ותו לא. הקוד מוסיף את ה-`/32` בעצמו, כך ש-`203.0.113.10/32` היה הופך ל-`203.0.113.10/32/32`. הכלל דוחה ערך כזה, וגם טקסט כמו `abc`. הכלי `Terraform` בודק את הכלל כשהוא מקבל ערך, בזמן `plan`, ולא הרצתי `plan`. בדקתי את אותה תבנית ב-`Python`: היא קיבלה את `203.0.113.10` ודחתה את `203.0.113.10/32` ואת `abc`.
* גם למשתנה `app_port` יש כלל אימות: מספר שלם מ-1 עד 65535, ולא 22, כי פורט האפליקציה פתוח לכולם, והערך 22 היה פותח לכולם גם את `SSH`. כמו ב-`my_ip`, הכלי `Terraform` בודק את הכלל הזה בזמן `plan`, ולא הרצתי `plan`.
* כל כלל הוא משאב נפרד (`aws_vpc_security_group_ingress_rule`, `aws_vpc_security_group_egress_rule`), ולא בלוק בתוך הקבוצה. לכל אחד יש תיאור משלו, ושינוי בכלל אחד לא נוגע באחרים. הכלי `Terraform` מסיר את כלל היציאה של ברירת המחדל מקבוצה חדשה, ולכן כלל היציאה כתוב במפורש.
* האימג' הוא אימג' השרת החדש ביותר של `Ubuntu 24.04` ל-`amd64`, שהבעלים שלו הוא החשבון של `Canonical`, `099720109477`. בזכות הסינון לפי בעלים, אימג' שמישהו אחר פרסם בשם דומה לא ייבחר אף פעם. חשבון ההתחברות של ברירת המחדל באימג'ים האלה הוא `ubuntu`, והוא מופיע ב-`ssh_command`.
* השרת דורש `IMDSv2` (`http_tokens = "required"`). בקשה לשירות ה-`metadata` צריכה קודם `token` של סשן, וזה חוסם את הדרך הפשוטה לקרוא את ה-`credentials` של השרת דרך בקשה מזויפת. דיסק השורש הוא `gp3` ומוצפן.
* השרת מבקש כתובת `IP` ציבורית בעצמו (`associate_public_ip_address = true`), כך שהפלטים לא תלויים בהגדרה של ה-`subnet` של ברירת המחדל.
* השתמשתי ב-`VPC` של ברירת המחדל, ולכן אין צורך לבנות רשת משלי.
* ההגדרה `default_tags` ב-`provider` שמה את `Project = "devops-portfolio"` ואת `ManagedBy = "terraform"` על כל משאב. לשרת יש גם את השם `portfolio-app`.
* הפלט `public_ip` מחזיק רק את הכתובת, כך שסקריפט יכול לקרוא אותו עם `terraform output -raw public_ip`.
* הכלי `git` מתעלם מ-`.terraform/`, מ-`*.tfstate`, מ-`*.tfstate.*`, מ-`*.tfvars` ומ-`*.tfvars.json`. ה-`state` מחזיק כל תכונה של המשאבים, והקובץ `terraform.tfvars` מחזיק כתובת אמיתית ושם `key pair` אמיתי. קובץ הדוגמה נגמר ב-`.example`, ולכן `git` שומר אותו. גם קובץ הנעילה נשמר ב-`git`, כי הוא חלק מהנעילה. בדקתי את כל זה עם `git check-ignore -v`.

## איך מריצים

כל הפקודות רצות משורש הריפו. הרצתי אותן ב-`PowerShell` על `Windows 11` עם `Docker Desktop` ועם האימג' `hashicorp/terraform:1.17.2`. אף אחת מהן לא צריכה `credentials` של `AWS`.

בודקים את העיצוב:

```
docker run --rm -v "${PWD}/04-terraform:/tf" -w /tf hashicorp/terraform:1.17.2 fmt -check -recursive -diff
```

הפקודה לא הדפיסה כלום ויצאה עם קוד `0`.

מתקינים את ה-`provider`, בלי `backend`:

```
docker run --rm -v "${PWD}/04-terraform:/tf" -w /tf hashicorp/terraform:1.17.2 init -backend=false -input=false
```

הפקודה הדפיסה `Installed hashicorp/aws v6.73.0 (signed by HashiCorp)` ו-`Terraform has been successfully initialized!`. זה לקח בערך דקה. ה-`provider` תופס בערך `770 MB` ב-`04-terraform/.terraform/`, והכלי `git` מתעלם מהתיקייה הזאת.

בודקים את הקוד:

```
docker run --rm -v "${PWD}/04-terraform:/tf" -w /tf hashicorp/terraform:1.17.2 validate
```

הפקודה הדפיסה `Success! The configuration is valid.`

לא הרצתי את הפקודות שלמטה. הן יוצרות שרת אמיתי בחשבון `AWS` וצריכות `credentials` של `AWS`. עם חשבון `AWS`, עם `credentials`, עם `key pair` קיים ועם `Terraform` מותקן, מריצים אותן מתוך `04-terraform/`. אחרי ההעתקה צריך לשים בקובץ `terraform.tfvars` כתובת אמיתית ושם `key pair` אמיתי.

```
cd 04-terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
terraform output
```

גם את `terraform destroy` לא הרצתי. הפקודה הזאת מוחקת את כל מה שנוצר.

## מה הייתי רוצה לשפר

* כדאי לשמור את ה-`state` ב-`backend` מרוחק עם נעילה, למשל `bucket` של `S3`. במצב הנוכחי ה-`state` יהיה קובץ מקומי במחשב אחד, ושום דבר לא ימנע משני אנשים להריץ `apply` באותו זמן.
* כדאי שהקוד יבנה `VPC` קטן ו-`subnet` משלו. בחלק מהחשבונות אין `VPC` של ברירת מחדל, ואז הקוד הזה נכשל.
* כתובת ה-`IP` הציבורית משתנה כשהשרת נעצר ועולה מחדש. עם `Elastic IP` הכתובת תישאר קבועה.
* כדאי לבדוק את הכלל של `my_ip` ואת הפלטים עם `terraform test` ועם `provider` מדומה, כך ש-`Terraform` עצמו יבדוק אותם בלי `AWS`.
* בקובץ הנעילה יש `checksum` מלא מסוג `h1` רק ל-`linux_amd64`, שם רץ ה-`init`. הרצת `init` על `Windows` או על `macOS` מוסיפה לו שורה. הפקודה `terraform providers lock` לפלטפורמות האלה תוסיף אותן מראש.
* פורט האפליקציה פתוח לכולם ומדבר `HTTP` רגיל. כדאי לשים לפניו `load balancer` עם `TLS`.
