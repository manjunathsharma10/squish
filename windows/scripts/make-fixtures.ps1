# Generates synthetic test files with ffmpeg: photos, graphics, a transparent
# PNG, videos (including a rotated one) and audio. Used by CI.
param([string]$Out = "fixtures")
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
function Make([string[]]$Arguments) {
    & ffmpeg -loglevel error -y @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed: $Arguments" }
}

# A detailed 12 MP "photo", a 2560 px graphic, and a PNG with a transparent hole.
Make @("-f", "lavfi", "-i", "mandelbrot=s=4032x3024:maxiter=600", "-frames:v", "1", "-q:v", "2", "$Out/Photo.jpg")
Make @("-f", "lavfi", "-i", "testsrc2=s=2560x1440", "-frames:v", "1", "$Out/Graphic.png")
Make @("-f", "lavfi", "-i", "testsrc2=s=1024x1024", "-frames:v", "1", "-vf",
       "format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(hypot(X-512,Y-512),300),0,255)'", "$Out/Transparent.png")

# Video: a high-bitrate 1080p clip (MOV), and a portrait clip stored rotated.
Make @("-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
       "-t", "6", "-c:v", "libx264", "-b:v", "25M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k", "$Out/Clip.mov")
Make @("-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-t", "4", "-c:v", "libx264", "-b:v", "20M", "-pix_fmt", "yuv420p", "$Out/landscape.mp4")
Make @("-display_rotation", "90", "-i", "$Out/landscape.mp4", "-c", "copy", "$Out/Portrait.mp4")
Remove-Item "$Out/landscape.mp4"

# Audio: uncompressed WAV and a 320 kbps MP3.
Make @("-f", "lavfi", "-i", "sine=frequency=330:sample_rate=44100", "-ac", "2", "-t", "20", "$Out/Voice.wav")
Make @("-f", "lavfi", "-i", "anoisesrc=d=20:c=pink:r=44100:a=0.3", "-ac", "2", "-c:a", "libmp3lame", "-b:a", "320k", "$Out/Song.mp3")

Get-ChildItem $Out | Format-Table Name, Length
