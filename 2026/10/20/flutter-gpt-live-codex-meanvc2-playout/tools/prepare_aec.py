#!/usr/bin/env python3
import pathlib,subprocess,urllib.request,tarfile,io,re,shutil
root=pathlib.Path(__file__).resolve().parents[1]
revision='2cec2f52e26646f93bd2d5498bbabf59cba18da9'
vendor=root/'vendor/webrtc-aec3'
if not vendor.exists():
 with urllib.request.urlopen(f'https://codeload.github.com/Enaium/webrtc-aec3/tar.gz/{revision}') as response:archive=response.read()
 vendor.mkdir(parents=True)
 with tarfile.open(fileobj=io.BytesIO(archive),mode='r:gz') as tf:
  for member in tf.getmembers():
   parts=member.name.split('/',1)
   if len(parts)<2 or not parts[1]:continue
   member.name=parts[1];tf.extract(member,vendor,filter='data')
# Private namespaces avoid C++ ODR/symbol collisions with flutter_webrtc's SDK.
for p in (vendor/'src').rglob('*'):
 if p.is_file() and p.suffix in ('.h','.cc','.cpp','.c'):
  s=p.read_text()
  for name in ('webrtc','rtc','absl'):
   s=re.sub(r'\b'+name+r'(?=\s*::)', 'lab_aec_'+name,s)
   s=re.sub(r'\b(namespace\s+|using\s+namespace\s+)'+name+r'\b',r'\1lab_aec_'+name,s)
  p.write_text(s)
# Explicit standard include and portable SIMD lane access for MSVC.
array_source=vendor/'src/audio_processing/audio_buffer.cc'
text=array_source.read_text()
if '#include <array>' not in text:
 text=text.replace('#include <cstdint>','#include <cstdint>\n#include <array>')
 array_source.write_text(text)
matched=vendor/'src/audio_processing/aec3/matched_filter_avx2.cc'
text=matched.read_text()
old='      s_acum += s_inst_hadd_256[0];\n      e_128[0] = s_acum - y[i];\n      s_acum += s_inst_hadd_256[4];\n      e_128[1] = s_acum - y[i];\n      s_acum += s_inst_hadd_256[1];\n      e_128[2] = s_acum - y[i];\n      s_acum += s_inst_hadd_256[5];\n      e_128[3] = s_acum - y[i];'
new='      float partial_sums[8], errors[4];\n      _mm256_storeu_ps(partial_sums, s_inst_hadd_256);\n      s_acum += partial_sums[0];\n      errors[0] = s_acum - y[i];\n      s_acum += partial_sums[4];\n      errors[1] = s_acum - y[i];\n      s_acum += partial_sums[1];\n      errors[2] = s_acum - y[i];\n      s_acum += partial_sums[5];\n      errors[3] = s_acum - y[i];\n      e_128 = _mm_loadu_ps(errors);'
if old in text:text=text.replace(old,new)
elif new not in text:raise RuntimeError('Unexpected matched_filter_avx2 SIMD source')
text=text.replace('    x2_sum += sum[0];\n    s += sum[1];','    float sum_values[4];\n    _mm_storeu_ps(sum_values, sum);\n    x2_sum += sum_values[0];\n    s += sum_values[1];')
matched.write_text(text)
print('Prepared private-namespace AEC3 extraction '+revision)
for os in ('macos',):
 target=root/'playout_audio'/os/'playout_audio/Sources/PlayoutCore'
 target.mkdir(parents=True,exist_ok=True)
 shutil.copytree(vendor/'src',target/'third_party/src',dirs_exist_ok=True)
 # Only ARM slices are used for the physical Apple test devices.
 for pattern in ('*_avx2.cc','*_sse2.cc','*_sse.cc'):
  for p in (target/'third_party/src').rglob(pattern):p.unlink()
 (target/'include').mkdir(exist_ok=True)
 for name in ('aec_engine','playout_slot','playout_pipeline'):
  shutil.copyfile(root/'native'/(name+'.h'),target/'include'/(name+'.h'))
  shutil.copyfile(root/'native'/(name+'.h'),target/(name+'.h'))
  shutil.copyfile(root/'native'/(name+'.cc'),target/(name+'.cc'))
