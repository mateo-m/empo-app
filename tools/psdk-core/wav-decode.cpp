// Reads a WAV file with SFML's own reader and writes the decoded 16-bit
// samples to stdout. test-wav-formats.sh builds this for the Mac, not for
// iOS, so a change to the reader can be checked in a second instead of
// through a full simulator run.
//
// The reader is the same source file the iOS build compiles, so what passes
// here is what the game gets.
#include <SFML/Audio/SoundFileReaderWav.hpp>
#include <SFML/System/InputStream.hpp>
#include <cstdio>
#include <cstdlib>
#include <vector>

class FileStream : public sf::InputStream
{
public:
    explicit FileStream(const char* path) { m_file = std::fopen(path, "rb"); }
    ~FileStream() { if (m_file) std::fclose(m_file); }
    bool ok() const { return m_file != NULL; }

    sf::Int64 read(void* data, sf::Int64 size)
    {
        return static_cast<sf::Int64>(std::fread(data, 1, static_cast<size_t>(size), m_file));
    }
    sf::Int64 seek(sf::Int64 position)
    {
        std::fseek(m_file, static_cast<long>(position), SEEK_SET);
        return tell();
    }
    sf::Int64 tell() { return std::ftell(m_file); }
    sf::Int64 getSize()
    {
        sf::Int64 here = tell();
        std::fseek(m_file, 0, SEEK_END);
        sf::Int64 size = tell();
        seek(here);
        return size;
    }

private:
    std::FILE* m_file;
};

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "usage: %s <file.wav> <sampleCount>\n", argv[0]); return 2; }

    FileStream stream(argv[1]);
    if (!stream.ok()) { std::fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    sf::priv::SoundFileReaderWav reader;
    sf::SoundFileReader::Info info;
    if (!sf::priv::SoundFileReaderWav::check(stream)) { std::fprintf(stderr, "check failed\n"); return 1; }
    stream.seek(0);
    if (!reader.open(stream, info)) { std::fprintf(stderr, "open failed\n"); return 1; }

    std::fprintf(stderr, "channels=%u rate=%u samples=%llu seconds=%.6f\n",
                 info.channelCount, info.sampleRate,
                 (unsigned long long)info.sampleCount,
                 double(info.sampleCount) / double(info.channelCount) / double(info.sampleRate));

    sf::Uint64 want = std::strtoull(argv[2], NULL, 10);
    std::vector<sf::Int16> buffer(static_cast<size_t>(want));
    sf::Uint64 got = reader.read(buffer.data(), want);
    std::fprintf(stderr, "read=%llu\n", (unsigned long long)got);
    std::fwrite(buffer.data(), sizeof(sf::Int16), static_cast<size_t>(got), stdout);
    return 0;
}
