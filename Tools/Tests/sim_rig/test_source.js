/*!
 * @name MeloX 测试音源
 * @description 仅供模拟器测试台使用，向本机测试服务请求播放地址
 * @version 1.0.0
 * @author MeloX
 */

const { EVENT_NAMES, request, on, send } = globalThis.lx

const BACKEND = '__BACKEND__'

on(EVENT_NAMES.request, ({ source, action, info }) => {
  if (action !== 'musicUrl' || source !== 'tx') {
    return Promise.reject(new Error('unsupported'))
  }
  const mid = info.musicInfo.songmid
  return new Promise((resolve, reject) => {
    request(
      `${BACKEND}/resolve?mid=${encodeURIComponent(mid)}&q=${encodeURIComponent(info.type)}`,
      { method: 'GET', timeout: 30000 },
      (error, response, body) => {
        if (error) return reject(error)
        if (body && body.url) return resolve(body.url)
        reject(new Error((body && body.error) || 'failed'))
      }
    )
  })
})

send(EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: {
    tx: {
      name: 'QQ',
      type: 'music',
      actions: ['musicUrl'],
      qualitys: __QUALITYS__,
    },
  },
})
