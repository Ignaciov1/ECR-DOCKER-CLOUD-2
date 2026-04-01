FROM nginx:alpine

# Eliminar contenido por defecto
RUN rm -rf /usr/share/nginx/html/*

# Copiar configuración de Nginx con UTF-8 forzado
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copiar archivos frontend
COPY . /usr/share/nginx/html

# Copiar archivos estáticos
COPY . /usr/share/nginx/html

EXPOSE 80
