"""Small statement splitter for checked-in plain SQL (no procedural dollar quotes).

Protects semicolons inside quoted strings and SQL line comments.
"""
def statements(sql: str):
    chunks=[]
    current=[]
    quote=None
    index=0
    while index<len(sql):
        c=sql[index]
        if quote is None and sql[index:index+2]=='--':
            end=sql.find('\n',index)
            if end<0:
                break
            index=end
            continue
        if c=="'":
            if quote is None:
                quote="'"
            elif quote=="'" and index+1<len(sql) and sql[index+1]=="'":
                current.append("''")
                index+=2
                continue
            elif quote=="'":
                quote=None
        if c==';' and quote is None:
            chunk=''.join(current).strip()
            if chunk: chunks.append(chunk+';')
            current=[]
        else:
            current.append(c)
        index+=1
    final=''.join(current).strip()
    if final: chunks.append(final)
    return chunks
