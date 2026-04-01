FROM nginx:alpine

# Eliminar contenido por defecto
RUN rm -rf /usr/share/nginx/html/*

# Copiar configuración de Nginx (Asegúrate de tener este archivo)
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copiar archivos frontend al directorio de Nginx
COPY . /usr/share/nginx/html

EXPOSE 80