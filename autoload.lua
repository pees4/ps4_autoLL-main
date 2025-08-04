
-- autoload.lua
-- This script loads and runs Lua scripts or ELF files from a specified directory on the PS5.
-- Lua scripts are executed directly, while ELF files are sent to a local server running on port 9021.

autoload = {}
autoload.options = {
    autoload_dirname = "ps5_lua_loader", -- directory where the elfs, lua scripts and autoload.txt are located
    autoload_config = "autoload.txt",
    autoload_hen= "payload.bin",
}


elf_sender = {}
elf_sender.__index = elf_sender


syscall.resolve(
    {
        sendto = 133
    }
)

function elf_sender:load_from_file(filepath)
    if not elf_loader_active then
        start_elf_loader()
    end

    if file_exists(filepath) then
        print("Loading elf from:", filepath)
        send_ps_notification("Loading elf from: \n" .. filepath)
    else
        print("[-] File not found:", filepath)
        send_ps_notification("[-] File not found: \n" .. filepath)
    end

    local self = setmetatable({}, elf_sender)
    self.filepath = filepath
    self.elf_data = file_read(filepath)
    self.elf_size = #self.elf_data

    print("elf size:", self.elf_size)
    return self
end

function elf_sender:sceNetSend(sockfd, buf, len, flags, addr, addrlen)
    return syscall.sendto(sockfd, buf, len, flags, addr, addrlen):tonumber()
end
function elf_sender:sceNetSocket(domain, type, protocol)
    return syscall.socket(domain, type, protocol):tonumber()
end
function elf_sender:sceNetSocketClose(sockfd)
    return syscall.close(sockfd):tonumber()
end
function elf_sender:htons(port)
    return bit32.bor(bit32.lshift(port, 8), bit32.rshift(port, 8)) % 0x10000
end

function elf_sender:send_to_localhost(port)

    local sockfd = elf_sender:sceNetSocket(2, 1, 0) -- AF_INET=2, SOCK_STREAM=1
    print("Socket fd:", sockfd)
    assert(sockfd >= 0, "socket creation failed")
    local enable = memory.alloc(4)
    memory.write_dword(enable, 1)
    syscall.setsockopt(sockfd, 1, 2, enable, 4) -- SOL_SOCKET=1, SO_REUSEADDR=2

    local sockaddr = memory.alloc(16)

    memory.write_byte(sockaddr + 0, 16)
    memory.write_byte(sockaddr + 1, 2) -- AF_INET
    memory.write_word(sockaddr + 2, elf_sender:htons(port))

    memory.write_byte(sockaddr + 4, 0x7F) -- 127
    memory.write_byte(sockaddr + 5, 0x00) -- 0
    memory.write_byte(sockaddr + 6, 0x00) -- 0
    memory.write_byte(sockaddr + 7, 0x01) -- 1

    local buf = memory.alloc(#self.elf_data)
    memory.write_buffer(buf, self.elf_data)

    local total_sent = elf_sender:sceNetSend(sockfd, buf, #self.elf_data, 0, sockaddr, 16)
    elf_sender:sceNetSocketClose(sockfd)
    if total_sent < 0 then
        print("[-] error sending elf data to localhost")
        send_ps_notification("error sending elf data to localhost")
        return
    end
    print(string.format("Successfully sent %d bytes to loader", total_sent))
end


function main()

    local internal_payload = "/data/payload.bin"
    local payload_paths = {}
    for usb = 0, 7 do
        table.insert(payload_paths, string.format("/mnt/usb%d/", usb))
    end
    local usb_path = nil
    for _, path in ipairs(payload_paths) do
        local full_path = path .. autoload.options.autoload_hen
        if file_exists(full_path) then
            usb_path = full_path
            break
        end
    end
    if not usb_path and not file_exists(internal_payload) then
        send_ps_notification("payload not found!")
        print("[-] payload not found!")
        return
    end
    if not usb_path and file_exists(internal_payload) then
        print("using internal payload: " .. internal_payload)
        return
    end
    if file_exists(internal_payload) then
        local internal_data = file_read2(internal_payload)
        local usb_data = file_read2(usb_path)
        if internal_data and usb_data and internal_data == usb_data then
            send_ps_notification("Payload already up to date!")
            print("[=] Payload already up to date in /data/payload.bin")
            return
        end
    end
    local new_payload = file_read2(usb_path)
    if not new_payload then
        print("[-] Failed to read payload from: " .. usb_path)
        return
    end
    local dest_path = io.open(internal_payload, "wb")
    if not dest_path then
        print("[-] Failed to open destination: " .. internal_payload)
        return
    end

    dest_path:write(new_payload)
    dest_path:close()

    send_ps_notification("Payload copied successfully!")
    print("[+] Payload copied successfully to /data/payload.bin")
end


main()
