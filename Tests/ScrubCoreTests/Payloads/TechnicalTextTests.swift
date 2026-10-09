import Foundation
@testable import ScrubCore
import Testing

// Technical text as staff paste it: an application's log, a stack trace, an
// environment file, an application's XML settings, a crash report and a
// verbose HTTP transcript, as a file, pasted, and as a string inside a JSON
// log line. Only the personal parts change; every key, path, separator and
// technical value stays as written. Every name, path and secret is invented.

private func scrub(_ text: String, as name: String) throws -> String {
    String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 7).output, as: UTF8.self)
}

/// The same text as a log file, as pasted text, and as the message of a JSON log line, read back out.
private let renderings: [(String, @Sendable (String) throws -> String)] = [
    ("log", { try scrub($0, as: "app.log") }),
    ("pasted", { try scrub($0, as: "Pasted text") }),
    ("jsonl", { text in
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            "{\"level\":\"info\",\"msg\":" + String(decoding: try! JSONEncoder().encode(String(line)), as: UTF8.self) + "}"
        }
        let output = try scrub(lines.joined(separator: "\n"), as: "events.jsonl")
        return try output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String], "no longer parses: \(line)")
            return try #require(object["msg"])
        }.joined(separator: "\n")
    }),
]

private let loginLog = """
2026-10-03 14:22:05,118 INFO  [http-nio-8080-exec-7] c.e.api.AuthController - Login attempt user=ofelia.brandvold@example.com ip=10.4.1.20
2026-10-03 14:22:05,402 ERROR [http-nio-8080-exec-7] c.e.api.ProfileService - Failed to load avatar for user ofelia.brandvold@example.com
2026-10-03 14:22:06,007 INFO  [http-nio-8080-exec-8] c.e.api.ResetController - GET /reset?email=ofelia.brandvold@example.com&lang=en 302 12ms
2026-10-03 14:22:06,310 INFO  [mailer-2] c.e.mail.Outbox - queued to=ofelia.brandvold@example.com from=noreply@example.org template=reset_v2
"""

/// A value after a key ("user=…", "to=…", "?email=…") is replaced and the key stays; one address
/// takes one stand-in whatever word or mark is written before it.
@Test(arguments: renderings.map(\.0))
private func aKeyBeforeAnAddressStaysAndTheAddressTakesOneStandIn(_ name: String) throws {
    let rendering = try #require(renderings.first { $0.0 == name })
    let output = try rendering.1(loginLog)
    #expect(!output.contains("ofelia") && !output.contains("brandvold"), "[\(name)] \(output)")
    for kept in ["Login attempt user=", " ip=", "avatar for user ", "GET /reset?email=", "&lang=en 302 12ms", "queued to=", " from=noreply@", " template=reset_v2"] {
        #expect(output.contains(kept), "[\(name)] \(kept) lost in \(output)")
    }
    let address = /[a-z]+(?:\.[a-z]+)?@example\.(?:com|org|net)/
    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.count == 4, "[\(name)] \(output)")
    let standIns = [("user=", lines[0]), ("for user ", lines[1]), ("?email=", lines[2]), ("to=", lines[3])].compactMap { cue, line in
        line.firstRange(of: cue).flatMap { line[$0.upperBound...].prefixMatch(of: address).map { String($0.output) } }
    }
    #expect(standIns.count == 4 && Set(standIns).count == 1, "[\(name)] \(standIns) in \(output)")
}

private let thread = """
From: Wilhelmina Castellanos <w.castellanos@example.com>
To: Jasper Thornquist <jasper.thornquist@example.org>
Subject: Re: Q4 freight rates

Hi Jasper,

Rates attached.

Wilhelmina

On Wed, Oct 1, 2026 at 4:12 PM Jasper Thornquist <jasper.thornquist@example.org> wrote:
> Sent 09:30 AM UTC Jasper Thornquist <jasper.thornquist@example.org>
> Hi Wilhelmina,
"""

/// A time's half of the day and its zone stay with the time: "4:12 PM" before a name and its address
/// keeps its "PM", and the name is the same person's as everywhere else in the thread.
@Test(arguments: ["thread.txt", "Pasted text"])
private func aTimeBeforeANameKeepsItsHalfOfTheDay(_ name: String) throws {
    let output = try scrub(thread, as: name)
    for word in ["Jasper", "Thornquist", "Wilhelmina", "Castellanos"] { #expect(!output.contains(word), "[\(name)] \(word) left in \(output)") }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let to = try #require(lines[1].firstMatch(of: /^To: ([A-Z][a-z]+ [A-Z][a-z]+) </)).output.1
    #expect(lines[10].hasPrefix("On Wed, Oct 1, 2026 at 4:12 PM \(to) <"), "[\(name)] \(lines[10])")
    #expect(lines[11].hasPrefix("> Sent 09:30 AM UTC \(to) <"), "[\(name)] \(lines[11])")
}

private let stackTrace = #"""
2026-10-03 14:22:05,402 ERROR [exec-7] c.e.api.ProfileService - Failed to load avatar for user ofelia.brandvold@example.com
java.io.FileNotFoundException: /Users/obrandvold/Library/Application Support/LedgerSync/cache/avatar_88213.png (No such file or directory)
	at com.example.api.ProfileService.loadAvatar(ProfileService.java:142)
Caused by: java.lang.IllegalStateException: cache dir /home/obrandvold/.cache/app not writable
  File "/home/obrandvold/venvs/ledger/lib/python3.12/site-packages/requests/api.py", line 59, in request
mail spool /var/mail/obrandvold is 98% full; see ~obrandvold/.forward
sync source C:\Users\rpembertonhale\AppData\Roaming\Ledgerly\settings.ini, backup \\files01\home\rpembertonhale\ledgerly
escaped "C:\\Users\\rpembertonhale\\AppData\\Local\\Temp\\upload.tmp"
opened file:///Users/obrandvold/Desktop/notes.txt
shared /Users/Shared/Ledgerly, /home/runner/work/app, C:\Users\Public\Desktop, /home/www-data/.ssh, /Users/$USER/Library, C:\Users\%USERNAME%\AppData, /home/*/logs
"""#

/// A home folder's account name is its owner's handle: replaced in every path, one stand-in for
/// one account, built as that person's address's stand-in is ("obrandvold" beside "ofelia.brandvold@…").
/// The rest of each path stays byte for byte, and a system's or a shared account stays.
@Test(arguments: renderings.map(\.0))
private func aHomeFoldersAccountIsItsOwnersHandle(_ name: String) throws {
    let rendering = try #require(renderings.first { $0.0 == name })
    let output = try rendering.1(stackTrace)
    for original in ["brandvold", "pembertonhale"] { #expect(!output.contains(original), "[\(name)] \(original) left in \(output)") }
    let email = try #require(output.firstMatch(of: /for user ([a-z]+)\.([a-z]+)@/), "[\(name)] \(output)")
    let handle = String(email.output.1.prefix(1) + email.output.2)
    let other = try #require(output.firstMatch(of: /C:\\Users\\([^\\]+)\\AppData\\Roaming/)).output.1
    for path in ["/Users/\(handle)/Library/Application Support/LedgerSync/cache/avatar_88213.png (No such", "dir /home/\(handle)/.cache/app not",
                 "\"/home/\(handle)/venvs/ledger/lib/python3.12/site-packages/requests/api.py\", line 59", "/var/mail/\(handle) is", "see ~\(handle)/.forward",
                 "file:///Users/\(handle)/Desktop/notes.txt", "\\\\files01\\home\\\(other)\\ledgerly", "\"C:\\\\Users\\\\\(other)\\\\AppData\\\\Local\\\\Temp\\\\upload.tmp\""] {
        #expect(output.contains(path), "[\(name)] \(path) not in \(output)")
    }
    #expect(other != handle, "[\(name)] \(output)")
    #expect(output.hasSuffix("shared /Users/Shared/Ledgerly, /home/runner/work/app, C:\\Users\\Public\\Desktop, /home/www-data/.ssh, /Users/$USER/Library, C:\\Users\\%USERNAME%\\AppData, /home/*/logs"), "[\(name)] \(output)")
}

private let crashReport = """
Process:               Ledgerly [4412]
Path:                  /Applications/Ledgerly.app/Contents/MacOS/Ledgerly
Identifier:            com.example.ledgerly
Version:               5.2.0 (5200)
Code Type:             ARM-64 (Native)
Parent Process:        launchd [1]
User ID:               501

Date/Time:             2026-10-06 21:14:03.271 +0100
OS Version:            macOS 14.6.1 (23G93)
Report Version:        12
Anonymous UUID:        3F2A9C1E-7B4D-4E8F-A0B1-C2D3E4F5A6B7
CrashReporter Key:     9c41d0e2a7b35f8c16e4d2a90b7c3e5f1a8d6b42

Crashed Thread:        0  Dispatch queue: com.apple.main-thread
Exception Type:        EXC_BAD_ACCESS (SIGSEGV)

Thread 0 Crashed:
0   Ledgerly   0x0000000100a3c1f4 DocumentStore.open(url:) + 212 (/Users/genevieve.oduya/src/ledgerly/Sources/DocumentStore.swift:88)
1   Ledgerly   0x0000000100a3b880 AppDelegate.application(_:open:) + 96

Last file: /Users/genevieve.oduya/Documents/Taxes/2025 return - Genevieve Oduya.ledger
"""

/// A crash report's "User ID" is the machine's account number, which the first account on every
/// machine shares: it stays. Its anonymous UUID and reporter key identify the machine, as a device's
/// ID does, and take stand-ins of their shape. The account's folder and the name it spells, written
/// in a file's name, are one person's.
@Test(arguments: ["crash.txt", "Pasted text"])
private func aCrashReportKeepsTheMachinesAccountNumber(_ name: String) throws {
    let output = try scrub(crashReport, as: name)
    #expect(output.contains("User ID:               501\n"), "[\(name)] \(output)")
    for original in ["genevieve", "Genevieve", "oduya", "Oduya", "3F2A9C1E-7B4D-4E8F-A0B1-C2D3E4F5A6B7", "9c41d0e2a7b35f8c16e4d2a90b7c3e5f1a8d6b42"] {
        #expect(!output.contains(original), "[\(name)] \(original) left in \(output)")
    }
    #expect(output.contains(/Anonymous UUID:        [0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\n/), "[\(name)] \(output)")
    #expect(output.contains(/CrashReporter Key:     [0-9a-f]{40}\n/), "[\(name)] \(output)")
    let folder = try #require(output.firstMatch(of: /Last file: \/Users\/([a-z]+)\.([a-z]+)\/Documents\/Taxes\/2025 return - ([A-Z][a-z]+) ([A-Z][a-z]+)\.ledger$/), "[\(name)] \(output)")
    #expect(folder.output.1 == folder.output.3.lowercased() && folder.output.2 == folder.output.4.lowercased(), "[\(name)] \(output)")
    #expect(output.contains("(/Users/\(folder.output.1).\(folder.output.2)/src/ledgerly/Sources/DocumentStore.swift:88)"), "[\(name)] \(output)")
    let unchanged = crashReport.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty && !$0.contains("UUID") && !$0.contains("Key:") && !$0.contains("oduya") }
    for line in unchanged { #expect(output.contains(line), "[\(name)] \(line) changed in \(output)") }
}

private let appConfig = #"""
<?xml version="1.0"?>
<configuration>
  <connectionStrings>
    <add name="Main" connectionString="Server=db01.internal.example.com;Database=orders;User Id=svc_orders;Password=Tr0ub4dor&amp;3x!;" providerName="System.Data.SqlClient"/>
    <add name="Reports" connectionString="Data Source=rpt.example.net,1433;Initial Catalog=reports;User ID=okafor.e;Pwd=&quot;p@ss;word&quot;;Encrypt=True"/>
    <add name="Blob" connectionString="DefaultEndpointsProtocol=https;AccountName=ledgerlyfiles;AccountKey=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3A=;EndpointSuffix=core.example.net"/>
  </connectionStrings>
  <appSettings>
    <add key="Environment" value="staging"/>
    <add key="Cache" value="kv://:s3cr3t-Cache-pw@cache.example.net:6379/0"/>
  </appSettings>
  <legacy>Server=db02.example.com;Uid=okafor.e;Pwd=Hunter2&lt;x&gt;;</legacy>
</configuration>
"""#

/// A connection string's password, key or user is replaced whole, however its container encodes it
/// (an entity, quotes around a ";"), and every other pair stays: a service's account, the server, the store.
@Test(arguments: ["app.xml", "Pasted text"])
private func aConnectionStringsSecretsAreReplacedWhole(_ name: String) throws {
    let output = try scrub(appConfig, as: name)
    for original in ["Tr0ub4dor", "3x!", "p@ss", "word&quot;", "Zm9vYmFy", "s3cr3t", "Cache-pw", "okafor", "Hunter2", "&lt;x&gt;"] {
        #expect(!output.contains(original), "[\(name)] \(original) left in \(output)")
    }
    for kept in ["Server=db01.internal.example.com;Database=orders;User Id=svc_orders;Password=", #"" providerName="System.Data.SqlClient"/>"#,
                 "Data Source=rpt.example.net,1433;Initial Catalog=reports;User ID=", ";Pwd=&quot;", "&quot;;Encrypt=True\"/>",
                 "DefaultEndpointsProtocol=https;AccountName=ledgerlyfiles;AccountKey=", ";EndpointSuffix=core.example.net\"/>",
                 #"<add key="Environment" value="staging"/>"#, #"value="kv://:"#, "@cache.example.net:6379/0\"/>", "<legacy>Server=db02.example.com;Uid="] {
        #expect(output.contains(kept), "[\(name)] \(kept) lost in \(output)")
    }
    let users = output.matches(of: /(?:User ID|Uid)=([^;]+);/).map { String($0.output.1) }
    #expect(users.count == 2 && users[0] == users[1], "[\(name)] \(users) in \(output)")
    #expect(output.contains(/Password=[A-Za-z0-9]+;"/), "[\(name)] \(output)")
}

private let curlTranscript = #"""
$ curl -v -b 'session=7f6e5d4c3b2a1908; theme=dark' https://api.example.com/v1/me
> GET /v1/me HTTP/1.1
> Host: api.example.com
> User-Agent: curl/8.4.0
> Cookie: session=7f6e5d4c3b2a1908; uid=u_55120; theme=dark; lang=en-GB
>
< HTTP/1.1 200 OK
< Set-Cookie: sid=Zx81kq0PbW3eTq; Path=/; Secure; HttpOnly; SameSite=Lax
< X-Request-Id: req_7Hc2kL9mQ
<
{"id":"usr_48213177","email":"ofelia.brandvold@example.com","name":"Ofelia Brandvold"}
"""#

/// A cookie header keeps every cookie's name, its separators and its settings: only a session's
/// value, a credential's or someone's ID is replaced, the same value with the same stand-in.
@Test(arguments: ["curl.txt", "Pasted text"])
private func aCookieHeaderKeepsItsNames(_ name: String) throws {
    let output = try scrub(curlTranscript, as: name)
    for original in ["7f6e5d4c3b2a1908", "55120", "Zx81kq0PbW3eTq", "brandvold", "Brandvold"] { #expect(!output.contains(original), "[\(name)] \(original) left in \(output)") }
    let header = try #require(output.firstMatch(of: /> Cookie: session=([^;]+); uid=u_[0-9]{5}; theme=dark; lang=en-GB\n/), "[\(name)] \(output)")
    #expect(output.contains("-b 'session=\(header.output.1); theme=dark' https://api.example.com/v1/me"), "[\(name)] \(output)")
    #expect(output.contains(/< Set-Cookie: sid=[A-Za-z0-9]+; Path=\/; Secure; HttpOnly; SameSite=Lax\n< X-Request-Id: req_7Hc2kL9mQ\n/), "[\(name)] \(output)")
}

private let environment = """
# Ledgerly local settings
APP_ENV=staging
DATABASE_URL=sql://okafor.e:Tr0ub4dor%263x@db01.internal.example.com:5432/orders
CACHE_URL=kv://:s3cr3t-Cache-pw@cache.example.net:6379/0
SQL_CONNECTION="Server=db02.example.com;User Id=okafor.e;Password=correct horse battery;Encrypt=True"
LOG_DIR=/home/eokafor/ledgerly/logs
ADMIN_EMAIL=emeka.okafor@example.com
MAX_RETRIES=5
"""

/// An environment file's links, connection strings and paths lose their secrets and their user, who
/// is one account throughout; every setting's name and every technical value stays.
@Test(arguments: [".env", "Pasted text"])
private func anEnvironmentFileKeepsItsSettings(_ name: String) throws {
    let output = try scrub(environment, as: name)
    for original in ["okafor", "Tr0ub4dor", "s3cr3t", "horse", "battery", "eokafor"] { #expect(!output.contains(original), "[\(name)] \(original) left in \(output)") }
    for kept in ["# Ledgerly local settings\nAPP_ENV=staging\nDATABASE_URL=sql://", "@db01.internal.example.com:5432/orders\nCACHE_URL=kv://:", "@cache.example.net:6379/0\n",
                 "SQL_CONNECTION=\"Server=db02.example.com;User Id=", ";Encrypt=True\"\nLOG_DIR=/home/", "/ledgerly/logs\nADMIN_EMAIL=", "\nMAX_RETRIES=5"] {
        #expect(output.contains(kept), "[\(name)] \(kept) lost in \(output)")
    }
    let email = try #require(output.firstMatch(of: /ADMIN_EMAIL=([a-z]+)\.([a-z]+)@/), "[\(name)] \(output)")
    #expect(output.contains("LOG_DIR=/home/\(email.output.1.prefix(1))\(email.output.2)/ledgerly/logs"), "[\(name)] \(output)")
}
