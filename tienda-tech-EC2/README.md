# Tienda productos Tecnologicos

Aplicación de ejemplo en 3 capas usando Docker y Docker Compose:

- Frontend: HTML + JavaScript (Nginx)
- Backend: Node.js + Express
- Base de datos: MySQL

## Estructura del proyecto

tienda-tech-EC2
├── docker-compose.yml
├── tienda-tech-frontend
│   ├── Dockerfile
│   ├── index.html
│   └── app.js
│   └── nginx.conf
├── tienda-tech-backend
│   ├── Dockerfile
│   ├── package.json
│   └── server.js
└── tienda-tech-db
    └── init.sql

## Requisitos
1. Docker instalado en EC2:
```bash
sudo yum install docker -y
```
2. Docker habilitado y en ejecución en EC2:
```bash
sudo systemctl enable docker
sudo systemctl start docker
```
3. Cliente Mysql instalado en EC2
```bash
sudo yum install -y mariadb105
```
4. instalar y habilitar Docker Compose
```bash
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

## Validar conectividad con RDS desde EC2
1. Insalar telnet en EC2
```bash
sudo yum install telnet -y
```
2. Validar comunicación con RDS
```bash
sudo telnet TU_ENDPOINT_RDS 3306
```

## Crear base de datos en RDS desde EC2
1. En EC2 en ruta /home/ec2-user/ crear archivo y copiar contenido init.sql y luego ejecutar
2. Ejecutar comando para crear base de datos y tablas con datos: 
```bash
sudo mysql -h TU_ENDPOINT_RDS -u admin -p < init.sql
```
3. Comprobar base de datos creada en RDS: 
```bash
sudo mysql -h TU_ENDPOINT_RDS -u admin -p -e "SHOW DATABASES;" ## Te pedira la contraseña y es la que generaste cuando creaste tu RDS.
```
4. Comprobar datos en base de datos creada en RDS: 
```bash
sudo mysql -h TU_ENDPOINT_RDS -u admin -p -e "USE tienda_tecnologica; SHOW TABLES; SELECT * FROM productos;"
```

## Ejecutar aplicación en Docker

1. En EC2 en ruta /home/ec2-user/ crear archivo y copiar contenido .env y docker-compose-yml
2. Editar archivo .env y cambiar a TU_ENDPOINT_RDS, cambiar a tu DB_USER, cambiar a tu DB_PASSWORD (Estos datos son cuando creaste tu RDS (usuario y contraseña) + endpoint RDS)
3. Editar archivo docker-compose.yml y cambiar el ID de tu cuenta AWS en el endpoint de tu ECR para FRONTEND Y BACKEND.
2. Ejecutar:
```bash
docker compose build
docker compose up -d
docker ps
docker compose logs backend
docker compose logs frontend
```
3. Abrir en el navegador:
- Frontend: http://IP_PUBLICA:80
- Backend (API): http://IP_PUBLICA:3001/api/productos

4. Para detener los contenedores:
```bash
docker compose down -v
```

5. Eliminar contenedores (opcional):
```bash
docker rm tienda-tech-backend
docker rm tienda-tech-frontend
```

## Notas
- La base de datos esta en RDS y al levantar los contenedores el backend apunta al endpoint del RDS.
- Puedes modificar el frontend y backend, reconstruir y volver a levantar los contenedores.
