# 1. Базовий образ з Python
FROM python:3.12-slim

# 2. Не створювати .pyc файли і одразу виводити логи
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# 3. Робоча папка всередині контейнера
WORKDIR /app

# 4. Спочатку копіюємо лише requirements.txt — так Docker кешує шар із залежностями
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 5. Копіюємо код застосунку і тести
COPY app ./app
COPY tests ./tests

# 6. Порт, на якому слухає застосунок
EXPOSE 8000

# 7. Команда запуску
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
