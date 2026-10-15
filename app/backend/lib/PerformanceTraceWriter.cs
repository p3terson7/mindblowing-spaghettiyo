// Diagnostic-only, bounded, single-writer sink. No PowerShell runs on this
// thread. Producers (including runspaces) enqueue already-redacted JSON lines.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Saphir.Diagnostics {
    public sealed class TraceWriter : IDisposable {
        readonly BlockingCollection<string> queue;
        readonly Thread thread;
        readonly string folder, prefix;
        readonly long maximumBytes;
        readonly int maximumFiles, flushMilliseconds;
        readonly List<string> paths = new List<string>();
        long dropped, failures, written, bytes, writeTicks;
        int sequence;
        volatile bool stopped;
        public long Dropped { get { return Interlocked.Read(ref dropped); } }
        public long Failures { get { return Interlocked.Read(ref failures); } }
        public long Written { get { return Interlocked.Read(ref written); } }
        public long BytesWritten { get { return Interlocked.Read(ref bytes); } }
        public long WriteTicks { get { return Interlocked.Read(ref writeTicks); } }
        public string[] FilePaths { get { lock (paths) { return paths.ToArray(); } } }
        [DllImport("libc", SetLastError = true)] static extern int chmod(string path, uint mode);
        public static void RestrictUnix(string path, bool directory) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) {
                if (chmod(path, directory ? 448u : 384u) != 0) throw new IOException("Diagnostic permissions unavailable.");
            }
        }
        public TraceWriter(string directory, long maxBytes, int maxFiles, int retentionDays, int capacity, int flushMs) {
            folder = directory; maximumBytes = maxBytes; maximumFiles = maxFiles;
            flushMilliseconds = flushMs;
            Directory.CreateDirectory(folder);
            RestrictUnix(folder, true);
            // Only our own diagnostic files; never inspect/delete business files.
            DateTime cutoff = DateTime.UtcNow.AddDays(-retentionDays);
            foreach (string file in Directory.GetFiles(folder, "SAPHIR-performance-*.jsonl")) {
                try { if (File.GetLastWriteTimeUtc(file) < cutoff) File.Delete(file); } catch { }
            }
            prefix = "SAPHIR-performance-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssfff") + "-" + Process.GetCurrentProcess().Id + "-" + Guid.NewGuid().ToString("N");
            queue = new BlockingCollection<string>(capacity);
            thread = new Thread(Consume); thread.IsBackground = true;
            thread.Name = "SAPHIR local diagnostic writer"; thread.Start();
        }
        public void Enqueue(string line) {
            try {
                // Protect memory and rotation even if a caller is defective.
                if (stopped || line == null || line.Length > 262144 || !queue.TryAdd(line)) Interlocked.Increment(ref dropped);
            } catch { Interlocked.Increment(ref dropped); }
        }
        StreamWriter OpenNext() {
            string file = Path.Combine(folder, prefix + "-" + (++sequence).ToString("D4") + ".jsonl");
            FileStream stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 16384);
            try { RestrictUnix(file, false); } catch { stream.Dispose(); throw; }
            lock (paths) {
                paths.Add(file);
                // Keep active process output bounded. Rotated files may contain
                // pieces of a trace: reports explicitly flag missing parents.
                while (paths.Count > maximumFiles) {
                    string old = paths[0]; paths.RemoveAt(0);
                    try { File.Delete(old); } catch { }
                }
            }
            return new StreamWriter(stream, new UTF8Encoding(false), 16384);
        }
        void Consume() {
            StreamWriter writer = null; long fileBytes = 0;
            Stopwatch sinceFlush = Stopwatch.StartNew(); int pending = 0;
            try {
                while (!queue.IsCompleted) {
                    string line;
                    if (queue.TryTake(out line, flushMilliseconds)) {
                        long start = Stopwatch.GetTimestamp();
                        try {
                            int size = Encoding.UTF8.GetByteCount(line) + Encoding.UTF8.GetByteCount(Environment.NewLine);
                            if (writer == null || fileBytes + size > maximumBytes) {
                                if (writer != null) writer.Dispose();
                                writer = OpenNext(); fileBytes = 0; pending = 0;
                            }
                            writer.WriteLine(line); fileBytes += size; pending++;
                            Interlocked.Increment(ref written); Interlocked.Add(ref bytes, size);
                        } finally { Interlocked.Add(ref writeTicks, Stopwatch.GetTimestamp() - start); }
                    }
                    if (writer != null && pending > 0 && (pending >= 64 || sinceFlush.ElapsedMilliseconds >= flushMilliseconds)) {
                        long flushStart = Stopwatch.GetTimestamp();
                        try { writer.Flush(); } finally { Interlocked.Add(ref writeTicks, Stopwatch.GetTimestamp() - flushStart); }
                        pending = 0; sinceFlush.Restart();
                    }
                }
            } catch { Interlocked.Increment(ref failures); stopped = true; }
            finally {
                try { if (writer != null) writer.Dispose(); } catch { Interlocked.Increment(ref failures); }
            }
        }
        public void Dispose() {
            if (!queue.IsAddingCompleted) queue.CompleteAdding();
            // Diagnostics must not hang server shutdown on a failed local disk.
            if (!thread.Join(5000)) { stopped = true; Interlocked.Increment(ref failures); }
            else { stopped = true; queue.Dispose(); }
        }
    }
}
