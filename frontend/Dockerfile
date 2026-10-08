FROM nginx:alpine

# Оновлюємо системні пакети Alpine до версій з виправленими вразливостями
# (сканер Trivy у CI блокує образ, якщо знаходить HIGH/CRITICAL вразливості)
RUN apk upgrade --no-cache

# Наш конфіг замість стандартного
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Статичні файли сайту
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
