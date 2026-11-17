// Serves the landing page on https://dictable.dev and sends every other hostname
// (www.dictable.dev, the *.workers.dev address) there with a permanent redirect.
const CANONICAL_HOST = 'dictable.dev';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname !== CANONICAL_HOST) {
      url.protocol = 'https:';
      url.hostname = CANONICAL_HOST;
      url.port = '';
      return Response.redirect(url.toString(), 301);
    }
    return env.ASSETS.fetch(request);
  },
};
