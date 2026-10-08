FROM nginx:alpine

# Наш конфіг замість стандартного
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Статичні файли сайту
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
