# Both stages use the same base, pinned by tag and digest, so the venv
# copied from the builder finds the same Python in the runtime stage.
FROM python:3.14.10-slim-trixie@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f AS builder

# No pip update check during the build. It only adds noise and a network call.
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# A venv puts all the app packages in one folder that the runtime stage can copy.
RUN python -m venv /opt/venv

COPY app/requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt


FROM python:3.14.10-slim-trixie@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f AS runtime

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# A fixed numeric id lets Kubernetes check runAsNonRoot. No home and no
# shell, because nobody ever logs in as this account.
RUN groupadd --gid 10001 appuser \
    && useradd --uid 10001 --gid 10001 --no-log-init --no-create-home \
       --home-dir /nonexistent --shell /usr/sbin/nologin appuser

# Only the installed packages and the app file. The files stay owned by
# root, so the app cannot change its own code.
COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY app/main.py .

# The version comes last, so a build with a new version reuses every layer above.
ARG APP_VERSION=0.1.0
LABEL org.opencontainers.image.title="portfolio-app" \
      org.opencontainers.image.version="${APP_VERSION}"
ENV APP_VERSION=${APP_VERSION}

USER 10001:10001

EXPOSE 8000

# The slim image has no curl, so the check uses Python. A refused
# connection, a timeout or an error status raises, and python exits with 1.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]

# 0.0.0.0 so the published port reaches the app from outside the container.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
