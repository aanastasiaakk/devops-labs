FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Оновлюємо системні пакети Debian і pip/setuptools базового образу до версій з виправленими
# вразливостями (сканер Trivy у CI блокує образ, якщо знаходить HIGH/CRITICAL вразливості)
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --upgrade pip setuptools wheel

COPY requirements.txt .
# Після встановлення залежностей pip у працюючому контейнері не потрібен - видаляємо його.
# Менше зайвих компонентів в образі; заодно зникає pip/_vendor/vendor.txt, через який
# Trivy знаходив вбудовану в pip стару setuptools 70.3.0 (CVE-2025-47273).
RUN pip install --no-cache-dir -r requirements.txt \
    && python -m pip uninstall -y pip

COPY app ./app
COPY tests ./tests
COPY pytest.ini .

# Версія застосунку передається при збиранні: docker build --build-arg APP_VERSION=1.0.0
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

EXPOSE 8001

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
