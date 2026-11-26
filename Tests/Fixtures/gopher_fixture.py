from socketserver import StreamRequestHandler, ThreadingTCPServer
import sys


class Handler(StreamRequestHandler):
    def handle(self):
        selector = self.rfile.readline(8192).rstrip(b"\r\n")
        authority = f"127.0.0.1\t{self.server.server_address[1]}\r\n".encode()
        entry = lambda item: item + b"\t" + authority
        if selector in (b"", b"/"):
            response = b"".join([
                entry(b"iLocal Gopher test server\t"),
                entry(b"0The old road\t/read"),
                entry(b"1Another menu\t/menu"),
                entry(b"7Search the trail index\t/query"),
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
