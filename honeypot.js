const net = require('net');
const fs = require('fs'); // Native Node module for reading/writing files
const path = require('path');

const PORT = 2222; // We use 2222 as our fake SSH port
const LOG_PATH = path.join(__dirname, 'logs', 'threat-logs.txt');

// Create the trap server
const server = net.createServer((socket) => {
    // 1. Grab the IP address of whoever just connected and clean IPv4-mapped IPv6 addresses
    let attackerIP = socket.remoteAddress;
    if (attackerIP && attackerIP.startsWith('::ffff:')) {
        attackerIP = attackerIP.slice(7);
    }
    
    const timestamp = new Date().toISOString();
    const logEntry = `[${timestamp}] Unauthorized access attempt from: ${attackerIP}\n`;

    // 2. Print it to our terminal so we can watch it live
    console.log(logEntry.trim());

    // 3. Save it permanently to a text file using the absolute path
    fs.appendFile(LOG_PATH, logEntry, (err) => {
        if (err) console.log("Failed to save log.");
    });

    // 4. Send a fake login prompt to trick the bot into thinking it found a real server
    socket.write("Ubuntu 24.04 LTS (GNU/Linux)\nlogin: ");

    // 5. Kick them out after 2 seconds so they don't consume our server memory
    setTimeout(() => {
        socket.destroy();
    }, 2000);
});

// Start listening on all available network interfaces (0.0.0.0)
server.listen(PORT, '0.0.0.0', () => {
    console.log(`[+] Security Honeypot active. Listening on port ${PORT}...`);
});