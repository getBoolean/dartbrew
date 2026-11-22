"""Generated SDK identity check that freeze_runtime.py still reads."""
import re


def generated_identity(text, source_head):
    result = {}
    for name, field, length in [('snapshot_hash_', 'snapshot_hash', 32),
                                ('git_short_hash_', 'git_short_hash', 10)]:
        values = re.findall(r'Version::' + name + r'\s*=\s*"([0-9a-f]+)";', text)
        if len(values) != 1 or len(values[0]) != length:
            raise RuntimeError(f'missing or ambiguous generated {field}')
        result[field] = values[0]
    if result['git_short_hash'] != source_head[:10]:
        raise RuntimeError('generated SDK hash does not match patched source HEAD')
    return result
