from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0004_passwordresettoken"),
    ]

    operations = [
        migrations.AlterField(
            model_name="user",
            name="role",
            field=models.CharField(
                choices=[
                    ("student", "Student"),
                    ("lecturer", "Lecturer"),
                    ("qa_staff", "QA staff"),
                    ("administrator", "Administrator"),
                    ("kiu_admin", "KIU administrator"),
                    ("vc", "Vice-Chancellor"),
                    ("dvc", "Deputy Vice-Chancellor"),
                    ("dqa", "Director of Quality Assurance"),
                    ("dean", "Dean"),
                    ("hod", "Head of Department"),
                ],
                default="student",
                max_length=32,
            ),
        ),
    ]
