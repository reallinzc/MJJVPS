const startedAt = Date.now()

const https = require('https')
const http = require('http')
const os = require('os')
const path = require('path')
const fs = require('fs')

process.env['NODE_TLS_REJECT_UNAUTHORIZED'] = 0
!(async () => {
  const startedAt = Date.now()
  // 下载原始内容
  const raw = await fetchContent(
    'https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.adg.list',
    {
      timeout: 30 * 1000,
    }
  )
  // 打印原始内容
  console.log(raw)
  // 分组
  const group = {}
  let lastName
  raw.split(/\r?\n/).forEach(line => {
    const matched = line.trim().match(/^#\s*?>\s*(.*)$/)
    const name = matched ? matched[1].trim() : null
    if (name) {
      if (!group[name]) {
        group[name] = []
      }
      lastName = name
    } else if (lastName && line.length && !line.startsWith('#')) {
      group[lastName].push(line.trim())
    }
  })
  // 打印分组结果
  console.log('分组结果:', group)
  // 按需生成需要的文件
  const output = [
    // 用法示例: 
    // 包含这些的, 连 dns 一起写入 此文件
    { file: '/root/dnsproxy/elseunlock.conf', include: ['Tiktok'], dns: 'https://hkg2.edge.access.zznet.fun/dns-query/else' },
    // 不包含这些的, 连 dns 一起写入 此文件
    { file: '/root/dnsproxy/unlock.conf', exclude: ['Tiktok', 'Youtube', 'Disney+'], dns: 'https://hkg2.edge.access.zznet.fun/dns-query' }
  ]
  output.forEach(({ file, include, exclude, dns }) => {
    const content = []
    console.log(`\n处理文件: ${file}`)
    if (include) {
      console.log(`包含组: ${include.join(', ')}`)
      include.forEach(name => {
        if (group[name]) {
          console.log(`\x1b[32m命中包含组: ${name}\x1b[0m`)
          content.push(...group[name])
        } else {
          console.log(`未命中包含组: ${name}`)
        }
      })
    }
    if (exclude) {
      console.log(`排除组: ${exclude.join(', ')}`)
      Object.keys(group).forEach(name => {
        if (!exclude.includes(name)) {
          console.log(`\x1b[32m不在排除组: ${name}\x1b[0m`)
          content.push(...group[name])
        } else {
          console.log(`\x1b[31m命中排除组: ${name}\x1b[0m`)
        }
      })
    }
    // const filepath = path.join(__dirname, file)
    fs.writeFileSync(file, content.map(i => i.replace(/\<DNS\>/g, dns)).join('\n'), 'utf-8')
    console.log(`📝 ${file} 已生成`)
  })

})()
  .catch(async e => {
    console.error('❌ 错误')
    console.error(e)
    process.exit(1)
  })
  .finally(() => {
    console.log(`耗时: ${((Date.now() - startedAt) / 1000 / 60).toFixed(2)} 分钟`)
    console.log(`✅ 完成`)
    process.exit(0)
  })

function fetchContent(url, options = {}) {
  const client = url.startsWith('https://') ? require('https') : require('http')

  return new Promise((resolve, reject) => {
    const timeout = options.timeout || 5000
    const req = client.get(url, options, res => {
      const { statusCode, headers } = res

      if (statusCode >= 200 && statusCode < 300) {
        let rawData = ''
        res.setEncoding('utf8')
        res.on('data', chunk => {
          console.log('data')
          rawData += chunk
        })
        res.on('end', () => {
          console.log('end')
          req.abort()
          resolve(rawData)
        })
      } else if (statusCode >= 300 && statusCode < 400 && headers.location) {
        const redirectUrl = new URL(headers.location, url)
        resolve(fetchContent(redirectUrl.toString(), options))
      } else {
        reject(new Error(`Request failed with status code ${statusCode}`))
      }
    })

    req.setTimeout(timeout, () => {
      req.abort()
      reject(new Error('Request timeout'))
    })

    req.on('error', e => {
      reject(e)
    })

    req.end()
  })
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}