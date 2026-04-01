CREATE DATABASE IF NOT EXISTS tienda_tecnologica;
USE tienda_tecnologica;

SET NAMES utf8mb4;
SET CHARACTER SET utf8mb4;

CREATE TABLE productos (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nombre VARCHAR(100),
  descripcion VARCHAR(255),
  precio DECIMAL(10,2),
  stock INT
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

INSERT INTO productos (nombre, descripcion, precio, stock) VALUES
('Laptop Lenovo ThinkPad', 'Intel i5, 16GB RAM, 512GB SSD', 799990, 5),
('Mouse Logitech MX Master 3', 'Mouse inalámbrico ergonómico', 10990, 12),
('Teclado Mecánico Redragon', 'Switch Blue, retroiluminado', 20990, 20),
('Monitor LG 27"', 'Full HD IPS', 179990, 7);
