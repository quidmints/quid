/**
 * ellipsify.ts — truncate a string with ellipsis in the middle
 */
export function ellipsify(str = '', len = 4): string {
  if (str.length <= len * 2 + 2) return str
  return `${str.slice(0, len)}..${str.slice(-len)}`
}
