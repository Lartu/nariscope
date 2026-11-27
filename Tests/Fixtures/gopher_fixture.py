from socketserver import StreamRequestHandler, ThreadingTCPServer
import sys
import time


class Handler(StreamRequestHandler):
    def handle(self):
        selector = self.rfile.readline(8192).rstrip(b"\r\n")
        authority = f"127.0.0.1\t{self.server.server_address[1]}\r\n".encode()
        entry = lambda item: item + b"\t" + authority
        if selector in (b"/large.bin", b"/preview-limit.bin", b"/slow.bin"):
            block = bytes(range(256)) * 256
            try:
                if selector == b"/slow.bin":
                    self.wfile.write(block)
                    time.sleep(5)
                else:
                    size_mib = 50 if selector == b"/preview-limit.bin" else 52
                    for _ in range(size_mib * 16):
                        self.wfile.write(block)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if selector in (b"", b"/"):
            response = b"".join([
                entry(b"iLocal Gopher test server\t"),
                entry(b"0The old road\t/read"),
                entry(b"1Another menu\t/menu"),
                entry(b"7Search the trail index\t/query"),
                entry(b"9Large binary fixture\t/large.bin"),
            ])
        elif selector == b"/read":
            response = (
                b"The old road leads through the forest and eventually reaches\r\n"
                b"a small village beside the river. Travellers usually stop here\r\n"
                b"before continuing north.\r\n\r\n"
                b"+-------+\r\n|  MAP  |\r\n+-------+\r\n"
            )
        elif selector == b"/menu":
            response = entry(b"0Read the article\t/read")
        elif selector == b"/query\tforest trail":
            response = entry(b"0Result for forest trail\t/read")
        else:
            response = b"3Unknown selector\t\tlocalhost\t70\r\n"
        self.wfile.write(response + b".\r\n")


with ThreadingTCPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0), Handler) as server:
    print(server.server_address[1], flush=True)
    server.serve_forever()
